#!/usr/bin/env bash
#
# T-008 AC-3 (spec.md の「README に inputs / outputs / 環境変数 / 対応OS / 対応バージョン
# (Linux動的、Windows対応表) / Troubleshooting (空き容量) が書かれている」) の検査。
#
# README.md に次の見出し (または同等の節) と内容があることを grep で検査する:
#   - `## Inputs`             version と method の説明
#   - `## Outputs`            version と rocm-path
#   - `## Environment Variables`  ROCM_PATH / ROCM_HOME / HIP_PATH / PATH / LD_LIBRARY_PATH
#   - 対応OS節 (Tested Platforms 等)  ubuntu-22.04 / windows-2022 / almalinux を含む
#   - 対応バージョン: Linux は動的に一覧を取得する旨 (取得元 repo.radeon.com への言及)、
#     Windows は対応表 (5.5.1 / 5.7.1 / 6.1.2 / 6.2.4 / 6.4.2 / 7.1.1 / 7.2.0)
#   - `## Troubleshooting`    `No space left on device` の項
#
# 使い方: test/ci/check_readme.sh

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

# ## Inputs (version と method の説明)
require_heading '## Inputs'
require_text 'version' "Inputs section mentions 'version'"
require_text 'method' "Inputs section mentions 'method'"

# ## Outputs (version と rocm-path)
require_heading '## Outputs'
require_text 'rocm-path' "Outputs section mentions 'rocm-path'"

# ## Environment Variables (ROCM_PATH / ROCM_HOME / HIP_PATH / PATH / LD_LIBRARY_PATH)
require_heading '## Environment Variables'
for var in ROCM_PATH ROCM_HOME HIP_PATH PATH LD_LIBRARY_PATH; do
	require_text "${var}" "Environment Variables section mentions ${var}"
done

# 対応OS (Tested Platforms 等の見出し) と、具体的なOS名
grep -qE '^## .*(Platform|Tested|Supported OS)' "${README}" ||
	fail "missing a heading for supported/tested platforms (e.g. '## Tested Platforms')"
for os in ubuntu-22.04 windows-2022 almalinux; do
	require_text "${os}" "supported platforms section mentions ${os}"
done

# 対応バージョン: Linux は動的取得 (取得元 repo.radeon.com への言及)、Windows は対応表
require_text 'repo\.radeon\.com' "mentions the dynamic Linux version source (repo.radeon.com)"
for v in 5.5.1 5.7.1 6.1.2 6.2.4 6.4.2 7.1.1 7.2.0; do
	require_text "${v//./\\.}" "Windows version table mentions ${v}"
done

# ## Troubleshooting (No space left on device)
require_heading '## Troubleshooting'
require_text 'No space left on device' "Troubleshooting section mentions 'No space left on device'"

echo "OK: README.md has the required sections (Inputs / Outputs / Environment Variables / Tested Platforms / version support / Troubleshooting)"
