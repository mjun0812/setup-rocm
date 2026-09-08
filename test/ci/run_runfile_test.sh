#!/usr/bin/env bash
#
# Verifies the Linux runfile route and `auto`'s fallback to it, by
# calling test/ci/run_full_test.sh's `verify` / `cross-compile`
# subcommands. A thin wrapper that does not modify run_full_test.sh
# itself (just calls it).
#
# The runfile installer index's
# (https://repo.radeon.com/rocm/installer/rocm-runfile-installer/)
# overall latest version and its 7.14-series latest version are
# fetched dynamically from the directory index on every run (not
# hard-coded; at the time of writing these are 10.0 and 7.14.1
# respectively).
#
# Usage:
#   test/ci/run_runfile_test.sh ac1   # ubuntu-22.04, version=latest, method=runfile
#   test/ci/run_runfile_test.sh ac2   # ubuntu-22.04, version=7.14, method=auto (falls back to runfile since package-manager doesn't have it)
#   test/ci/run_runfile_test.sh ac3   # verifies the cross-compile on ac1's run (ubuntu-22.04, latest, runfile)
#
# Dependencies: curl, git, gh (authenticated with the workflow scope).
# Shares the same assumptions as run_full_test.sh. Written to run
# under macOS's bash 3.2 too (no associative arrays).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_FULL_TEST="${SCRIPT_DIR}/run_full_test.sh"
RUNFILE_INDEX_URL='https://repo.radeon.com/rocm/installer/rocm-runfile-installer/'

log() {
	echo "[run_runfile_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_runfile_test] ERROR: $*" >&2
	exit 1
}

# Returns the numeric version strings (e.g. "7.14.1", "10.0") parsed
# from the runfile installer index's `rocm-rel-<ver>/` entries, sorted
# ascending.
fetch_runfile_versions() {
	curl -fsSL "${RUNFILE_INDEX_URL}" \
		| grep -oE 'href="rocm-rel-[^"]*/"' \
		| sed -E 's/^href="rocm-rel-//; s#/"$##' \
		| grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
		| sort -t. -k1,1n -k2,2n -k3,3n
}

# Escapes a version string for use in a regex (escaping "." as "\.")
# and wraps it in ^...$.
version_regex() {
	local escaped
	escaped="$(printf '%s' "$1" | sed 's/\./\\./g')"
	printf '^%s$' "${escaped}"
}

cmd_ac1() {
	local versions latest regex
	log "fetching runfile version list from ${RUNFILE_INDEX_URL} to determine the overall latest"
	versions="$(fetch_runfile_versions)"
	[ -n "${versions}" ] || fail "no runfile versions found at ${RUNFILE_INDEX_URL}"
	latest="$(echo "${versions}" | tail -n1)"
	log "runfile list overall latest: ${latest}"
	regex="$(version_regex "${latest}")"
	"${RUN_FULL_TEST}" verify ubuntu-22.04 latest runfile "${regex}" /opt/rocm
}

cmd_ac2() {
	local versions latest_714 regex
	log "fetching runfile version list from ${RUNFILE_INDEX_URL} to determine the 7.14 series latest"
	versions="$(fetch_runfile_versions)"
	latest_714="$(echo "${versions}" | grep -E '^7\.14(\.|$)' | tail -n1)"
	[ -n "${latest_714}" ] || fail "no 7.14 series runfile version found at ${RUNFILE_INDEX_URL}"
	log "runfile list 7.14 series latest: ${latest_714}"
	regex="$(version_regex "${latest_714}")"
	"${RUN_FULL_TEST}" verify ubuntu-22.04 7.14 auto "${regex}" /opt/rocm
}

cmd_ac3() {
	# Reuses the same (os, version, method) run as ac1, via run_full_test.sh's cache.
	"${RUN_FULL_TEST}" cross-compile ubuntu-22.04 latest runfile
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
