#!/usr/bin/env bash
#
# T-006 (Linux runfile経路と `auto` のfallback (統合)) の
# Acceptance Criteria を、test/ci/run_full_test.sh (T-004の検査ハーネス) の
# `verify` / `cross-compile` サブコマンドを呼び出して検証する薄いラッパー。
# run_full_test.sh 自体は変更しない (呼び出すだけ)。
#
# runfile installer の一覧 (https://repo.radeon.com/rocm/installer/rocm-runfile-installer/) の
# 「全体の最新版」「7.14系の最新版」は、実行のたびにディレクトリindexから動的に取得する
# (hard-codeしない。執筆時点ではそれぞれ 10.0 / 7.14.1)。
#
# 使い方:
#   test/ci/run_runfile_test.sh ac1   # AC-1: ubuntu-22.04, version=latest, method=runfile
#   test/ci/run_runfile_test.sh ac2   # AC-2: ubuntu-22.04, version=7.14, method=auto (package-managerに無くrunfileへfallback)
#   test/ci/run_runfile_test.sh ac3   # AC-3: AC-1と同じ run (ubuntu-22.04, latest, runfile) でのクロスコンパイル検証
#
# 依存: curl, git, gh (workflow scope で認証済み)。run_full_test.sh と同じ前提を共有する。
# macOS の bash 3.2 でも動く構文 (連想配列を使わない) にしている。

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

# runfile installer index の `rocm-rel-<ver>/` エントリから、数値バージョン文字列
# (例: "7.14.1"、"10.0") を数値順 (昇順) で1行ずつ返す
fetch_runfile_versions() {
	curl -fsSL "${RUNFILE_INDEX_URL}" \
		| grep -oE 'href="rocm-rel-[^"]*/"' \
		| sed -E 's/^href="rocm-rel-//; s#/"$##' \
		| grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
		| sort -t. -k1,1n -k2,2n -k3,3n
}

# バージョン文字列を正規表現エスケープ (「.」を「\.」に) し、^...$ で囲む
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
	# AC-1 と同じ (os, version, method) の run を run_full_test.sh のキャッシュ経由で再利用する
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
