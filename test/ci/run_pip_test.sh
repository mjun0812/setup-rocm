#!/usr/bin/env bash
#
# T-004 (Linux pip route installs ROCm into an action-local venv and lets a
# later step cross-compile with hipcc) Acceptance Criteria, verified against a
# real GitHub-hosted runner by calling the `dispatch` / `wait` / `cross-compile`
# subcommands of test/ci/run_full_test.sh (the T-004 harness for the
# package-manager route). run_full_test.sh itself is not modified.
#
# The run id cache file naming (STATE_DIR/run-<os>-<version>-<method>.id) uses
# the same convention as run_full_test.sh, so this script's dispatch and
# run_full_test.sh's `cross-compile` subcommand can share the same run.
#
# run_full_test.sh's `verify` subcommand expects an exact match on
# outputs.rocm-path (e.g. /opt/rocm), which does not hold for the pip route:
# rocm-path is a path under <RUNNER_TEMP>/setup-rocm-venv chosen at runtime by
# `rocm-sdk path --root`. So this script performs its own log-based
# verification (outputs.version regex, outputs.rocm-path / ROCM_PATH prefix
# match against the RUNNER_TEMP value, hipcc --version output). Cross-compile
# (gfx942) is OS/method-independent, so run_full_test.sh's `cross-compile` is
# reused as-is.
#
# Contract shared with the implementation:
#   - .github/workflows/full-test.yml (registered on main) exposes a
#     workflow_dispatch with os / version / method (all string inputs), and
#     `method` accepts "pip".
#   - _test.yml's Linux verification step echoes the action's outputs and
#     environment as `outputs.version=<value>` / `outputs.rocm-path=<value>` /
#     `ROCM_PATH=<value>` / `RUNNER_TEMP=<value>`, one per line, and runs
#     `hipcc --version` (its "HIP version" output is grepped for).
#   - A step whose name contains "Cross-compile" runs
#     `hipcc --offload-arch=gfx942 -c` on a minimal HIP source.
#
# Usage:
#   test/ci/run_pip_test.sh ac1   # AC-1: ubuntu-22.04, method=pip, version=latest
#   test/ci/run_pip_test.sh all   # every AC assigned to this harness (currently: ac1)
#
# Dependencies: git, gh (authenticated with the workflow scope). Shares the
# same assumptions as run_full_test.sh. Written to run under macOS's bash 3.2
# too (no associative arrays).
#
# The branch under test (feat/setup-rocm) is assumed to already be pushed to
# origin; this script does not push (checked by require_pushed_head inside
# run_full_test.sh's dispatch_run).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_FULL_TEST="${SCRIPT_DIR}/run_full_test.sh"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"

# run id (databaseId) format. gh run list --json databaseId is always numeric.
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_pip_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_pip_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

# Same naming convention as run_full_test.sh's run_id_file, so this script and
# run_full_test.sh's cross-compile subcommand can share the same cached run.
run_id_file() {
	local os="$1" version="$2" method="$3" key
	key="$(printf '%s-%s-%s' "${os}" "${version}" "${method}" | tr '/: ' '___')"
	echo "${STATE_DIR}/run-${key}.id"
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

# Dispatches via run_full_test.sh's `dispatch` subcommand and waits for it to
# complete, failing unless the run succeeds.
dispatch_and_wait() {
	local os="$1" version="$2" method="$3"
	local id conclusion

	id="$("${RUN_FULL_TEST}" dispatch "${os}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "dispatch_and_wait: captured run id '${id}' is not numeric (os=${os})"

	conclusion="$("${RUN_FULL_TEST}" wait "${id}")"
	log "run ${id} (os=${os}) conclusion=${conclusion}"
	[ "${conclusion}" = "success" ] || fail "run ${id} (os=${os}) did not succeed (conclusion=${conclusion})"

	echo "${id}"
}

# A cached run is only reused when its headSha matches the current HEAD (so a
# successful run from another commit is never treated as evidence for the
# current change).
run_matches_head() {
	local id="$1" sha
	sha="$(gh run view "${id}" --json headSha --jq .headSha)"
	[ "${sha}" = "$(git -C "${REPO_ROOT}" rev-parse HEAD)" ]
}

# Reuses a cached run id (waiting for it again) if present, otherwise dispatches.
get_or_dispatch_and_wait() {
	local os="$1" version="$2" method="$3" f cached conclusion
	f="$(run_id_file "${os}" "${version}" "${method}")"
	if [ -s "${f}" ]; then
		cached="$(cat "${f}")"
		if [[ "${cached}" =~ ${RUN_ID_RE} ]]; then
			if run_matches_head "${cached}"; then
				log "reusing cached run id for os=${os} version=${version} method=${method}: ${cached}"
				conclusion="$("${RUN_FULL_TEST}" wait "${cached}")"
				[ "${conclusion}" = "success" ] || fail "run ${cached} (os=${os}) did not succeed (conclusion=${conclusion})"
				echo "${cached}"
				return
			fi
			log "cached run ${cached} for os=${os} version=${version} method=${method} was built from another commit; re-dispatching"
			rm -f "${f}"
			dispatch_and_wait "${os}" "${version}" "${method}"
			return
		fi
		log "cached run id file ${f} does not contain a plain numeric run id; ignoring and re-dispatching"
		rm -f "${f}"
	fi
	dispatch_and_wait "${os}" "${version}" "${method}"
}

# AC-1: verifies outputs.version / outputs.rocm-path / ROCM_PATH / hipcc for
# the pip route. Unlike run_full_test.sh's `verify` (exact match on
# rocm-path), rocm-path here is only known to be a subdirectory of
# <RUNNER_TEMP>/setup-rocm-venv, so it is checked as a prefix against the
# RUNNER_TEMP value the _test.yml verification step echoes.
# hipcc_name is only used in failure messages (e.g. "hipcc" / "hipcc.exe"), so
# this same function can be reused for the Windows pip route by a later task.
verify_pip_outputs() {
	local os="$1" version="$2" method="$3" hipcc_name="$4"
	local id log_file out_version out_rocm_path env_rocm_path runner_temp expected_prefix

	id="$(get_or_dispatch_and_wait "${os}" "${version}" "${method}")"
	log_file="$(fetch_log "${id}")"

	out_version="$(grep -oE 'outputs\.version=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.version=//' | tr -d '\r')"
	out_rocm_path="$(grep -oE 'outputs\.rocm-path=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.rocm-path=//' | tr -d '\r')"
	env_rocm_path="$(grep -oE 'ROCM_PATH=.*' "${log_file}" | tail -n1 | sed -E 's/^ROCM_PATH=//' | tr -d '\r')"
	runner_temp="$(grep -oE 'RUNNER_TEMP=.*' "${log_file}" | tail -n1 | sed -E 's/^RUNNER_TEMP=//' | tr -d '\r')"

	[ -n "${out_version}" ] || fail "run ${id} (os=${os}): outputs.version not found in log"
	echo "${out_version}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "run ${id} (os=${os}): outputs.version='${out_version}' does not match ^[0-9]+\.[0-9]+\.[0-9]+\$"

	[ -n "${runner_temp}" ] || fail "run ${id} (os=${os}): RUNNER_TEMP= not found in log (the _test.yml verification step must echo it)"

	expected_prefix="${runner_temp}/setup-rocm-venv/"
	case "${out_rocm_path}" in
	"${expected_prefix}"*) ;;
	*) fail "run ${id} (os=${os}): outputs.rocm-path='${out_rocm_path}' does not start with '${expected_prefix}'" ;;
	esac
	case "${env_rocm_path}" in
	"${expected_prefix}"*) ;;
	*) fail "run ${id} (os=${os}): ROCM_PATH='${env_rocm_path}' does not start with '${expected_prefix}'" ;;
	esac

	grep -qE 'HIP version' "${log_file}" || fail "run ${id} (os=${os}): ${hipcc_name} --version output ('HIP version') not found in log"

	log "OK for os=${os}: version=${out_version} rocm-path=${out_rocm_path}"
}

cmd_ac1() {
	verify_pip_outputs ubuntu-22.04 latest pip hipcc
	"${RUN_FULL_TEST}" cross-compile ubuntu-22.04 latest pip
}

cmd_all() {
	cmd_ac1
}

main() {
	local cmd="${1:-}"
	case "${cmd}" in
	ac1)
		cmd_ac1
		;;
	all)
		cmd_all
		;;
	*)
		echo "usage: $0 {ac1|all}" >&2
		exit 2
		;;
	esac
}

main "$@"
