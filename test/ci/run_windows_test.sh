#!/usr/bin/env bash
#
# Verifies the Windows HIP SDK installer route by calling
# test/ci/run_full_test.sh's `dispatch` / `wait` / `cross-compile`
# subcommands. run_full_test.sh itself is not modified.
#
# run_full_test.sh's `verify` assumes a Linux-style
# `hipcc --version|HIP version` check, which may not hold on Windows
# when it falls back to `clang --version`; so this wrapper performs its
# own verification of outputs / environment variables / hipcc-or-clang
# (fetching the dispatched run's log and grepping it itself). The
# cross-compile check is OS-independent, so run_full_test.sh's
# `cross-compile` is reused as-is.
#
# The run id cache file naming (STATE_DIR/run-<os>-<version>-<method>.id)
# follows the same convention as run_full_test.sh, so this script's
# dispatch and run_full_test.sh's cross-compile can share the same run.
#
# Contract shared with the implementation:
#   - .github/workflows/full-test.yml (registered on main)'s
#     workflow_dispatch can start a Windows job with os / version /
#     method.
#   - _test.yml's Windows verification step echoes the action's outputs
#     and environment as `outputs.version=<value>` /
#     `outputs.rocm-path=<value>` / `ROCM_PATH=<value>` in PowerShell,
#     one per line, and runs `hipcc --version` (falling back to
#     `clang --version` if unavailable).
#   - A step whose name contains "Cross-compile" runs
#     `hipcc --offload-arch=gfx942 -c`.
#
# On the pip-wheel route, Windows's `auto` picks the latest version
# from the union of the installer and pip lists, so windows-2022's
# `latest auto` resolves to pip's 10.0.0 rather than the installer's
# 7.2.0. That version's rocm-path lives under a venv (checked as a
# prefix match against `<RUNNER_TEMP>\setup-rocm-venv\` rather than an
# exact match); passing `venv` as verify_windows_outputs's 5th argument
# switches to that check. windows-2025's `latest auto` is intentionally
# not covered by cmd_ac1.
#
# Usage:
#   test/ci/run_windows_test.sh ac1   # windows-2022, method=auto, version=latest
#   test/ci/run_windows_test.sh ac2   # windows-2022, method=auto, version=6.4
#   test/ci/run_windows_test.sh ac3   # verifies the cross-compile on ac1's windows-2022 run
#
# Dependencies: git, gh (authenticated with the workflow scope). Shares
# the same assumptions as run_full_test.sh. Written to run under
# macOS's bash 3.2 too (no associative arrays).
#
# The branch under test (feat/setup-rocm) is assumed to already be
# pushed to origin; this script does not push (pushing is outside a
# verifier's responsibility).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_FULL_TEST="${SCRIPT_DIR}/run_full_test.sh"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"

# Format of a run id (databaseId). gh run list --json databaseId is always numeric.
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_windows_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_windows_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

# Same naming convention as run_full_test.sh's run_id_file, so this
# script's dispatch and run_full_test.sh's cross-compile can point at
# the same run.
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

# Dispatches via run_full_test.sh's `dispatch` subcommand and waits for
# it to complete, failing unless the run succeeds.
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


# A cached run is only reused when its headSha matches the current
# HEAD (so a successful run from another commit is never treated as
# evidence for the current change; the dispatching run_full_test.sh
# also requires that origin/<branch> matches HEAD).
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

# Verifies outputs (version / rocm-path), the ROCM_PATH environment
# variable, and hipcc --version (falling back to clang --version).
# Passing `venv` as expected_rocm_path switches from an exact match to
# a prefix check against `<RUNNER_TEMP>\setup-rocm-venv\` (the pip
# route's rocm-path is resolved at runtime via `rocm-sdk path --root`,
# so unlike the other routes it does not match a fixed path exactly).
verify_windows_outputs() {
	local os="$1" version="$2" method="$3" version_regex="$4" expected_rocm_path="$5"
	local id log_file out_version out_rocm_path env_rocm_path runner_temp expected_prefix

	id="$(get_or_dispatch_and_wait "${os}" "${version}" "${method}")"
	log_file="$(fetch_log "${id}")"

	out_version="$(grep -oE 'outputs\.version=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.version=//' | tr -d '\r')"
	out_rocm_path="$(grep -oE 'outputs\.rocm-path=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.rocm-path=//' | tr -d '\r')"
	env_rocm_path="$(grep -oE 'ROCM_PATH=.*' "${log_file}" | tail -n1 | sed -E 's/^ROCM_PATH=//' | tr -d '\r')"

	[ -n "${out_version}" ] || fail "run ${id} (os=${os}): outputs.version not found in log"
	echo "${out_version}" | grep -qE "${version_regex}" || fail "run ${id} (os=${os}): outputs.version='${out_version}' does not match ${version_regex}"

	if [ "${expected_rocm_path}" = "venv" ]; then
		runner_temp="$(grep -oE 'RUNNER_TEMP=.*' "${log_file}" | tail -n1 | sed -E 's/^RUNNER_TEMP=//' | tr -d '\r')"
		[ -n "${runner_temp}" ] || fail "run ${id} (os=${os}): RUNNER_TEMP= not found in log (the _test.yml verification step must echo it)"
		expected_prefix="${runner_temp}\\setup-rocm-venv\\"
		case "${out_rocm_path}" in
		"${expected_prefix}"*) ;;
		*) fail "run ${id} (os=${os}): outputs.rocm-path='${out_rocm_path}' does not start with '${expected_prefix}'" ;;
		esac
		case "${env_rocm_path}" in
		"${expected_prefix}"*) ;;
		*) fail "run ${id} (os=${os}): ROCM_PATH='${env_rocm_path}' does not start with '${expected_prefix}'" ;;
		esac
	else
		[ "${out_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): outputs.rocm-path='${out_rocm_path}' != '${expected_rocm_path}'"
		[ "${env_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): ROCM_PATH='${env_rocm_path}' != '${expected_rocm_path}'"
	fi

	grep -qE 'HIP version|clang version' "${log_file}" || fail "run ${id} (os=${os}): neither 'HIP version' (hipcc --version) nor 'clang version' (clang --version) output found in log"

	log "OK for os=${os}: version=${out_version} rocm-path=${out_rocm_path}"
}

cmd_ac1() {
	verify_windows_outputs windows-2022 latest auto '^10\.0\.0$' venv
}

cmd_ac2() {
	verify_windows_outputs windows-2022 6.4 auto '^6\.4\.2$' 'C:\Program Files\AMD\ROCm\6.4'
}

cmd_ac3() {
	# Reuses ac1's windows-2022 (latest) run via run_full_test.sh's cache.
	"${RUN_FULL_TEST}" cross-compile windows-2022 latest auto
}

main() {
	local cmd="${1:-}"
	case "${cmd}" in
	ac1)
		cmd_ac1
		;;
	ac2)
		cmd_ac2
		;;
	ac3)
		cmd_ac3
		;;
	*)
		echo "usage: $0 {ac1|ac2|ac3}" >&2
		exit 2
		;;
	esac
}

main "$@"
