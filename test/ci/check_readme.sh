#!/usr/bin/env bash
#
# Verifies that README.md documents inputs / outputs / environment
# variables / tested platforms / version support (dynamic on Linux, a
# table on Windows) / Troubleshooting (disk space).
#
# Checks via grep that README.md has the following headings (or
# equivalent sections) and content:
#   - `## Inputs`                  describes version and method
#   - `## Outputs`                 version and rocm-path
#   - `## Environment Variables`   ROCM_PATH / ROCM_HOME / HIP_PATH / PATH / LD_LIBRARY_PATH
#   - a tested-platforms section (e.g. Tested Platforms) mentioning
#     ubuntu-22.04 / windows-2022 / almalinux
#   - version support: Linux fetches its version list dynamically
#     (mentions the source, repo.radeon.com), Windows has a version
#     table (5.5.1 / 5.7.1 / 6.1.2 / 6.2.4 / 6.4.2 / 7.1.1 / 7.2.0)
#   - `## Troubleshooting`         a "No space left on device" entry
#
# Usage: test/ci/check_readme.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
README="${REPO_ROOT}/README.md"

fail() {
	echo "[check_readme] FAIL: $*" >&2
	exit 1
}

[ -f "${README}" ] || fail "not found: ${README}"

require_heading() {
	local heading="$1"
	grep -qE "^${heading}([[:space:]]|$)" "${README}" || fail "missing heading: '${heading}'"
}

require_text() {
	local pattern="$1" desc="$2"
	grep -qiE -- "${pattern}" "${README}" || fail "missing: ${desc} (pattern: ${pattern})"
}

# ## Inputs (describes version and method)
require_heading '## Inputs'
require_text 'version' "Inputs section mentions 'version'"
require_text 'method' "Inputs section mentions 'method'"

# ## Outputs (version and rocm-path)
require_heading '## Outputs'
require_text 'rocm-path' "Outputs section mentions 'rocm-path'"

# ## Environment Variables (ROCM_PATH / ROCM_HOME / HIP_PATH / PATH / LD_LIBRARY_PATH)
require_heading '## Environment Variables'
for var in ROCM_PATH ROCM_HOME HIP_PATH PATH LD_LIBRARY_PATH; do
	require_text "${var}" "Environment Variables section mentions ${var}"
done

# Tested-platforms section (e.g. Tested Platforms) and specific OS names
grep -qE '^## .*(Platform|Tested|Supported OS)' "${README}" ||
	fail "missing a heading for supported/tested platforms (e.g. '## Tested Platforms')"
for os in ubuntu-22.04 windows-2022 almalinux; do
	require_text "${os}" "supported platforms section mentions ${os}"
done

# Version support: Linux fetches its list dynamically (mentions the source, repo.radeon.com); Windows has a version table
require_text 'repo\.radeon\.com' "mentions the dynamic Linux version source (repo.radeon.com)"
for v in 5.5.1 5.7.1 6.1.2 6.2.4 6.4.2 7.1.1 7.2.0; do
	require_text "${v//./\\.}" "Windows version table mentions ${v}"
done

# ## Troubleshooting (No space left on device)
require_heading '## Troubleshooting'
require_text 'No space left on device' "Troubleshooting section mentions 'No space left on device'"

# pip route section: a dedicated heading describing the pip installation route.
# Exclude FAQ-style question headings (e.g. "### Does this support installing ROCm via pip
# wheels ...?") so an existing question that merely mentions pip does not satisfy this check.
grep -E '^#{2,3} .*[Pp]ip' "${README}" | grep -qvE '\?[[:space:]]*$' ||
	fail "missing a heading for the pip route (e.g. '## Installing via pip')"

# pip route facts: index URL, installed packages, venv location, rocm-path location,
# the Python prerequisite, and the difference from the same-named packages on PyPI
require_text 'https://stable\.repo\.amd\.com/rocm/core/whl-next/' "pip index URL"
require_text 'rocm\[devel\]' "pip package rocm[devel]"
require_text 'rocm-sdk-core' "pip package rocm-sdk-core"
require_text 'rocm-sdk-devel' "pip package rocm-sdk-devel"
require_text 'setup-rocm-venv' "venv location (setup-rocm-venv)"
require_text 'rocm-sdk path --root' "rocm-path location (rocm-sdk path --root)"
require_text 'actions/setup-python' "Python prerequisite guidance (actions/setup-python)"
require_text 'PyPI' "difference from the same-named packages on PyPI"

# `method` input Options list includes `pip`
require_text '`pip`' "method input Options list mentions pip"

echo "OK: README.md has the required sections (Inputs / Outputs / Environment Variables / Tested Platforms / version support / Troubleshooting / pip route)"
