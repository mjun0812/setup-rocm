#!/usr/bin/env bash
#
# Verifies the unresolved-version failure path on a GitHub-hosted runner:
# a `version: 99.9` step on ubuntu-22.04 fails while wrapped in
# `continue-on-error` (checked via `outcome == 'failure'`), and the log
# reports that the version was not found together with the source URL
# it looked it up from.
#
# Dispatches .github/workflows/full-test.yml (workflow_dispatch: os /
# version / method / debug / expect-failure) via `gh workflow run` with
# expect-failure=true, then checks the run's log for the not-found
# message and the source URL.
#
# Structured after test/ci/run_full_test.sh / test/ci/run_container_test.sh
# (dispatch -> run id lookup (numeric check) -> polling -> log
# verification, macOS bash 3.2 compatible, discards `gh workflow run`'s
# stdout, and a dispatch lock to avoid mixing up runs across concurrent
# invocations). Unlike those, this script dispatches on its own instead
# of reusing run_full_test.sh's `dispatch` subcommand, because that
# subcommand only forwards os/version/method to `-f` and cannot add
# `expect-failure` (run_full_test.sh itself is left unmodified).
#
# Contract shared with the implementation:
#   - .github/workflows/full-test.yml's workflow_dispatch has an
#     expect-failure input (boolean, default false), forwarded as-is to
#     the reusable workflow _test.yml.
#   - _test.yml's action step (id: setup-rocm) carries
#     `continue-on-error: ${{ inputs.expect-failure }}`.
#   - When expect-failure=true, a step verifies that
#     `steps.setup-rocm.outcome == 'failure'` and that the log contains
#     a message about the unresolved version (containing `not found`)
#     and the source URL of the version list, failing the job/run only
#     if that assertion fails. Since the action step itself is
#     continue-on-error, the run's overall conclusion is correctly
#     `success` when it completes.
#
# Usage:
#   test/ci/run_failure_test.sh ac2   # verifies ubuntu-22.04, version=99.9, method=auto, expect-failure=true
#   test/ci/run_failure_test.sh dispatch <os> <version> <method>
#   test/ci/run_failure_test.sh wait <run_id>
#
# Dependencies: git, gh (authenticated with the workflow scope). Shares
# the same assumptions as test/ci/run_full_test.sh. Written to run
# under macOS's bash 3.2 too (no associative arrays).
#
# While unimplemented (RED): full-test.yml / _test.yml has no
# expect-failure input, so `gh workflow run full-test.yml ...
# -f expect-failure=true` fails with an "Unexpected inputs"-type error
# (dispatch_run's gh workflow run exits non-zero, and this script fails
# too).
#
# The branch under test (feat/setup-rocm) is assumed to already be
# pushed to origin; this script does not push (pushing is outside a
# verifier's responsibility). After getting the RED result, the failed
# run's cache (test/ci/.state/run-ubuntu-22.04-99.9-auto.id) should be
# removed by the caller (so a later re-verification, once implemented,
# doesn't pick up the stale run id).

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
# .state/*.id. Uses the same lock directory name as
# test/ci/run_full_test.sh, since it dispatches the same workflow
# (full-test.yml), so this script serializes with run_full_test.sh /
# run_windows_test.sh (see run_full_test.sh's DISPATCH_LOCK_DIR
# definition for details).
DISPATCH_LOCK_DIR="${STATE_DIR}/.dispatch.lock"
DISPATCH_LOCK_TIMEOUT="${DISPATCH_LOCK_TIMEOUT:-120}"

# Format of a run id (databaseId). gh run list --json databaseId is always numeric.
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_failure_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_failure_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

# The cache key is os-version-method (expect-failure is not included:
# this harness is dedicated to expect-failure=true, so it always
# dispatches with the same combination).
run_id_file() {
	local os="$1" version="$2" method="$3" key
	key="$(printf '%s-%s-%s' "${os}" "${version}" "${method}" | tr '/: ' '___')"
	echo "${STATE_DIR}/run-${key}.id"
}

# Returns the run ids already recorded in .state/run-*.id, as one
# space-padded line. Used as an exclusion list so a new dispatch's
# discovery does not re-pick a run already claimed by another
# concurrently running process (e.g. run_full_test.sh).
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
	# to .state/*.id.
	acquire_dispatch_lock
	require_pushed_head

	before_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	log "gh workflow run ${WORKFLOW} --ref ${BRANCH} -f os=${os} -f version=${version} -f method=${method} -f expect-failure=true"
	# bash's command substitution ($()) doesn't let an inner set -e trigger
	# an early exit, so a failure of gh workflow run itself is detected
	# explicitly here and fails immediately via fail().
	# stdout is discarded to /dev/null: newer gh versions print the run URL
	# to stdout on success, and without discarding it, the caller's
	# `id="$(dispatch_run ...)"` would capture both the URL line and the
	# actual databaseId line together.
	gh workflow run "${WORKFLOW}" --ref "${BRANCH}" \
		-f "os=${os}" -f "version=${version}" -f "method=${method}" -f "expect-failure=true" \
		>/dev/null ||
		fail "gh workflow run ${WORKFLOW} failed for os=${os} version=${version} method=${method} expect-failure=true (expect-failure input missing on full-test.yml/_test.yml?)"

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

# Verifies that the action step fails (via expect-failure=true) for
# version: 99.9, that the `steps.setup-rocm.outcome == 'failure'` check
# passes so the run completes overall as success, and that the log
# reports the version was not found together with the source URL
# (repo.radeon.com/rocm/apt/)
cmd_ac2() {
	local os="ubuntu-22.04" version="99.9" method="auto"
	local id conclusion log_file

	id="$(get_or_dispatch_run "${os}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "cmd_ac2: captured run id '${id}' is not numeric"

	conclusion="$(wait_run "${id}")"
	log "run ${id} (os=${os} version=${version} method=${method}) conclusion=${conclusion}"
	[ "${conclusion}" = "success" ] || fail "run ${id} did not succeed (conclusion=${conclusion}); expected 'success' because the failing action step must be continue-on-error"

	log_file="$(fetch_log "${id}")"

	grep -qi 'not found' "${log_file}" || fail "run ${id}: 'not found' message not found in log"
	grep -qF 'https://repo.radeon.com/rocm/apt/' "${log_file}" || fail "run ${id}: source URL 'https://repo.radeon.com/rocm/apt/' not found in log"

	log "OK: run ${id} succeeded overall with expect-failure=true, and logged the not-found message and source URL"
}

main() {
	local cmd="${1:-}"
	case "${cmd}" in
	dispatch)
		shift
		dispatch_run "$@"
		;;
	wait)
		shift
		wait_run "$@"
		;;
	ac2)
		cmd_ac2
		;;
	*)
		echo "usage: $0 {dispatch|wait|ac2} [args...]" >&2
		exit 2
		;;
	esac
}

main "$@"
