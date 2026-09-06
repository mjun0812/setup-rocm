#!/usr/bin/env bash
#
# Verifies the package-manager route on GitHub-hosted runners: a
# minimal-harness that dispatches .github/workflows/full-test.yml
# (workflow_dispatch: os / version / method) via `gh workflow run` and
# checks the action's outputs, environment variables, hipcc, and a
# gfx942 cross-compile from the run's log and job steps.
#
# Contract shared with the implementation:
#   - .github/workflows/full-test.yml has a workflow_dispatch with
#     inputs os (string) / version (string, default latest) / method
#     (string, default auto), and calls the reusable workflow
#     .github/workflows/_test.yml via `uses:`.
#   - _test.yml's verification step echoes the action's outputs as
#     `outputs.version=<value>` / `outputs.rocm-path=<value>`, one per
#     line, and also echoes `ROCM_PATH=$ROCM_PATH`. It runs
#     `hipcc --version`.
#   - A step whose name contains "Cross-compile" compiles a minimal HIP
#     source (a single __global__ kernel) with
#     `hipcc --offload-arch=gfx942 -c`.
#
# Usage:
#   test/ci/run_full_test.sh push       # push the current HEAD to origin/feat/setup-rocm (prerequisite; run once)
#   test/ci/run_full_test.sh ac1        # verifies outputs, environment variables, and hipcc on ubuntu-22.04 / ubuntu-24.04
#   test/ci/run_full_test.sh ac2        # verifies the cross-compile (Cross-compile step) on the same combinations
#   test/ci/run_full_test.sh verify <os> <version> <method> <version_regex> <expected_rocm_path>
#   test/ci/run_full_test.sh cross-compile <os> <version> <method>
#
# Dependencies: git, gh (authenticated with the workflow scope). Falls
# back to gh's built-in --jq if jq is unavailable. Written to run under
# macOS's bash 3.2 too (no associative arrays).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"
WORKFLOW="full-test.yml"
BRANCH="feat/setup-rocm"

# Polling interval and timeout while waiting for a run to complete (seconds)
POLL_INTERVAL="${POLL_INTERVAL:-30}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

# Wait time for a dispatched run to appear in gh run list (seconds)
DISPATCH_WAIT_INTERVAL=3
DISPATCH_WAIT_TIMEOUT=60

# Lock that serializes dispatch -> run id lookup -> recording to
# .state/*.id. Running multiple processes concurrently would let each
# one's find_new_run_id (right after its own `gh workflow run`) pick
# the same "most recent run created after dispatch", causing both to
# grab the same run. This section is serialized with mkdir (atomic) to
# prevent that race.
DISPATCH_LOCK_DIR="${STATE_DIR}/.dispatch.lock"
DISPATCH_LOCK_TIMEOUT="${DISPATCH_LOCK_TIMEOUT:-120}"

# Format of a run id (databaseId). gh run list --json databaseId is always numeric.
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_full_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_full_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

run_id_file() {
	local os="$1" version="$2" method="$3" key
	key="$(printf '%s-%s-%s' "${os}" "${version}" "${method}" | tr '/: ' '___')"
	echo "${STATE_DIR}/run-${key}.id"
}

# Returns the run ids already recorded in .state/run-*.id, as one
# space-padded line. Used as an exclusion list so a new dispatch's
# discovery does not re-pick a run already claimed by another
# concurrently running process.
claimed_run_ids() {
	local f v ids=""
	for f in "${STATE_DIR}"/run-*.id; do
		[ -f "${f}" ] || continue
		v="$(cat "${f}" 2>/dev/null || true)"
		[[ "${v}" =~ ${RUN_ID_RE} ]] || continue
		ids="${ids} ${v}"
	done
	echo " ${ids} "
}

# Lock for the dispatch -> run id lookup -> recording to .state/*.id
# section. mkdir fails if the directory already exists, so it gives
# atomic mutual exclusion.
acquire_dispatch_lock() {
	local waited=0
	while ! mkdir "${DISPATCH_LOCK_DIR}" 2>/dev/null; do
		waited=$((waited + 1))
		if [ "${waited}" -gt "${DISPATCH_LOCK_TIMEOUT}" ]; then
			fail "could not acquire dispatch lock (${DISPATCH_LOCK_DIR}) within ${DISPATCH_LOCK_TIMEOUT}s (stale lock from a crashed process? remove it manually if so)"
		fi
		sleep 1
	done
	# Trap as soon as the lock is acquired, so it is still released on an
	# abnormal exit via fail().
	trap release_dispatch_lock EXIT
}

release_dispatch_lock() {
	rmdir "${DISPATCH_LOCK_DIR}" 2>/dev/null || true
}

# The commit under test is the local HEAD. Dispatch only happens when
# origin/${BRANCH} matches HEAD, and a cached run is only reused when
# its headSha matches HEAD (so a successful run from an older commit is
# never treated as evidence for the current change).
target_sha() {
	git -C "${REPO_ROOT}" rev-parse HEAD
}

require_pushed_head() {
	local head remote
	head="$(target_sha)"
	remote="$(git -C "${REPO_ROOT}" ls-remote origin "refs/heads/${BRANCH}" | cut -f1)"
	[ "${remote}" = "${head}" ] ||
		fail "origin/${BRANCH} (${remote:-none}) does not match HEAD (${head}); push HEAD first"
}

run_matches_head() {
	local id="$1" sha
	sha="$(gh run view "${id}" --json headSha --jq .headSha)"
	[ "${sha}" = "$(target_sha)" ]
}

do_push() {
	log "push HEAD ($(git -C "${REPO_ROOT}" rev-parse --short HEAD)) to origin/${BRANCH}"
	git -C "${REPO_ROOT}" push -u origin "HEAD:refs/heads/${BRANCH}"
}

# Returns the newest databaseId of a workflow_dispatch run created
# after before_ts, from gh run list's most recent 5 entries (empty
# string if none). Only numeric databaseId values are trusted.
find_new_run_id() {
	local before_ts="$1"
	local best_id="" best_created="" rid rcreated revent
	local claimed
	claimed="$(claimed_run_ids)"
	while IFS="$(printf '\t')" read -r rid rcreated revent; do
		[ -z "${rid}" ] && continue
		[[ "${rid}" =~ ${RUN_ID_RE} ]] || continue
		case "${claimed}" in
		*" ${rid} "*) continue ;;
		esac
		[ "${revent}" = "workflow_dispatch" ] || continue
		if [[ "${rcreated}" > "${before_ts}" ]]; then
			if [ -z "${best_created}" ] || [[ "${rcreated}" > "${best_created}" ]]; then
				best_id="${rid}"
				best_created="${rcreated}"
			fi
		fi
	done < <(gh run list --workflow "${WORKFLOW}" --branch "${BRANCH}" \
		--json databaseId,createdAt,event --limit 5 \
		--jq '.[] | [(.databaseId|tostring), .createdAt, .event] | @tsv')
	echo "${best_id}"
}

dispatch_run() {
	local os="$1" version="$2" method="$3"
	local before_ts id waited

	# Excludes other processes from dispatch -> run id lookup -> recording
	# to .state/*.id. (Serializes concurrently running verify/cross-compile
	# calls so they don't mix up each other's runs; see the DISPATCH_LOCK_DIR
	# definition for details.)
	acquire_dispatch_lock
	require_pushed_head

	before_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	log "gh workflow run ${WORKFLOW} --ref ${BRANCH} -f os=${os} -f version=${version} -f method=${method}"
	# bash's command substitution ($()) doesn't let an inner set -e trigger
	# an early exit, so a failure of gh workflow run itself is detected
	# explicitly here and fails immediately via fail() (otherwise the
	# discovery loop below would spin uselessly until its timeout).
	# stdout is discarded to /dev/null: newer gh versions print the run URL
	# to stdout on success, and without discarding it, the caller's
	# `id="$(dispatch_run ...)"` would capture both the URL line and the
	# actual databaseId line together (this was the cause of a run id
	# extraction bug).
	gh workflow run "${WORKFLOW}" --ref "${BRANCH}" \
		-f "os=${os}" -f "version=${version}" -f "method=${method}" \
		>/dev/null ||
		fail "gh workflow run ${WORKFLOW} failed for os=${os} version=${version} method=${method}"

	log "waiting for the dispatched run to appear in gh run list..."
	waited=0
	id=""
	while [ "${waited}" -lt "${DISPATCH_WAIT_TIMEOUT}" ]; do
		id="$(find_new_run_id "${before_ts}")"
		[ -n "${id}" ] && break
		sleep "${DISPATCH_WAIT_INTERVAL}"
		waited=$((waited + DISPATCH_WAIT_INTERVAL))
	done

	[ -n "${id}" ] || fail "could not find the dispatched run for os=${os} version=${version} method=${method} within ${DISPATCH_WAIT_TIMEOUT}s"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "dispatched run id '${id}' is not numeric (os=${os} version=${version} method=${method})"

	log "dispatched run id: ${id}"
	echo "${id}" >"$(run_id_file "${os}" "${version}" "${method}")"

	# Release the lock as soon as recording is done, so other processes'
	# dispatch isn't kept waiting (the following wait_run can take a long
	# time, so it's kept out of the lock's scope).
	release_dispatch_lock

	echo "${id}"
}

get_or_dispatch_run() {
	# Helper so outputs/cross-compile verification can share the same run.
	# Dispatches on its own if there's no run id cache (or it's broken), so
	# it also works when called standalone.
	local os="$1" version="$2" method="$3" f cached
	f="$(run_id_file "${os}" "${version}" "${method}")"
	if [ -s "${f}" ]; then
		cached="$(cat "${f}")"
		if [[ "${cached}" =~ ${RUN_ID_RE} ]]; then
			if run_matches_head "${cached}"; then
				log "reusing cached run id for os=${os} version=${version} method=${method}: ${cached}"
				echo "${cached}"
				return
			fi
			log "cached run ${cached} for os=${os} version=${version} method=${method} was built from another commit; re-dispatching"
			rm -f "${f}"
			dispatch_run "${os}" "${version}" "${method}"
			return
		fi
		log "cached run id file ${f} does not contain a plain numeric run id; ignoring and re-dispatching"
		rm -f "${f}"
	fi
	dispatch_run "${os}" "${version}" "${method}"
}

wait_run() {
	local id="$1" waited=0 status="" conclusion
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "wait_run: run id '${id}' is not numeric"
	while [ "${waited}" -lt "${POLL_TIMEOUT}" ]; do
		status="$(gh run view "${id}" --json status --jq .status)"
		log "run ${id} status=${status} (${waited}s elapsed)"
		[ "${status}" = "completed" ] && break
		sleep "${POLL_INTERVAL}"
		waited=$((waited + POLL_INTERVAL))
	done

	[ "${status}" = "completed" ] || fail "run ${id} did not complete within ${POLL_TIMEOUT}s (last status=${status})"

	conclusion="$(gh run view "${id}" --json conclusion --jq .conclusion)"
	echo "${conclusion}"
}

fetch_log() {
	local id="$1"
	local log_file="${STATE_DIR}/log-${id}.txt"
	if [ ! -s "${log_file}" ]; then
		log "fetching log for run ${id}"
		gh run view "${id}" --log >"${log_file}"
	fi
	echo "${log_file}"
}

# Verifies outputs (version / rocm-path), the ROCM_PATH environment
# variable, and hipcc --version
verify_outputs() {
	local os="$1" version="$2" method="$3" version_regex="$4" expected_rocm_path="$5"
	local id conclusion log_file out_version out_rocm_path env_rocm_path

	id="$(get_or_dispatch_run "${os}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "verify_outputs: captured run id '${id}' is not numeric (os=${os})"

	conclusion="$(wait_run "${id}")"
	log "run ${id} (os=${os}) conclusion=${conclusion}"
	[ "${conclusion}" = "success" ] || fail "run ${id} (os=${os}) did not succeed (conclusion=${conclusion})"

	log_file="$(fetch_log "${id}")"

	out_version="$(grep -oE 'outputs\.version=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.version=//' | tr -d '\r')"
	out_rocm_path="$(grep -oE 'outputs\.rocm-path=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.rocm-path=//' | tr -d '\r')"
	env_rocm_path="$(grep -oE 'ROCM_PATH=.*' "${log_file}" | tail -n1 | sed -E 's/^ROCM_PATH=//' | tr -d '\r')"

	[ -n "${out_version}" ] || fail "run ${id} (os=${os}): outputs.version not found in log"
	echo "${out_version}" | grep -qE "${version_regex}" || fail "run ${id} (os=${os}): outputs.version='${out_version}' does not match ${version_regex}"

	[ "${out_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): outputs.rocm-path='${out_rocm_path}' != '${expected_rocm_path}'"
	[ "${env_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): ROCM_PATH='${env_rocm_path}' != '${expected_rocm_path}'"

	grep -qE 'hipcc --version|HIP version' "${log_file}" || fail "run ${id} (os=${os}): hipcc --version output not found in log"

	log "OK for os=${os}: version=${out_version} rocm-path=${out_rocm_path}"
}

# Verifies the cross-compile of a minimal HIP source (Cross-compile step)
verify_cross_compile() {
	local os="$1" version="$2" method="$3"
	local id conclusion log_file step_conclusion

	id="$(get_or_dispatch_run "${os}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "verify_cross_compile: captured run id '${id}' is not numeric (os=${os})"

	conclusion="$(wait_run "${id}")"
	[ "${conclusion}" = "success" ] || fail "run ${id} (os=${os}) did not succeed (conclusion=${conclusion})"

	step_conclusion="$(gh run view "${id}" --json jobs \
		--jq '[.jobs[0].steps[] | select(.name | test("Cross-compile"; "i"))][0].conclusion // empty')"
	[ -n "${step_conclusion}" ] || fail "run ${id} (os=${os}): no step with name containing 'Cross-compile' found"
	[ "${step_conclusion}" = "success" ] || fail "run ${id} (os=${os}): Cross-compile step conclusion=${step_conclusion}"

	log_file="$(fetch_log "${id}")"
	grep -qE -- '--offload-arch=gfx942' "${log_file}" || fail "run ${id} (os=${os}): --offload-arch=gfx942 not found in log"

	log "OK for os=${os}: Cross-compile step succeeded"
}

cmd_ac1() {
	local os
	for os in ubuntu-22.04 ubuntu-24.04; do
		verify_outputs "${os}" latest package-manager '^[0-9]+\.[0-9]+\.[0-9]+$' /opt/rocm
	done
}

cmd_ac2() {
	local os
	for os in ubuntu-22.04 ubuntu-24.04; do
		verify_cross_compile "${os}" latest package-manager
	done
}

main() {
	local cmd="${1:-}"
	case "${cmd}" in
	push)
		do_push
		;;
	dispatch)
		shift
		dispatch_run "$@"
		;;
	wait)
		shift
		wait_run "$@"
		;;
	verify)
		shift
		verify_outputs "$@"
		;;
	cross-compile)
		shift
		verify_cross_compile "$@"
		;;
	ac1)
		cmd_ac1
		;;
	ac2)
		cmd_ac2
		;;
	*)
		echo "usage: $0 {push|dispatch|wait|verify|cross-compile|ac1|ac2} [args...]" >&2
		exit 2
		;;
	esac
}

main "$@"
