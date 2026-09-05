#!/usr/bin/env bash
#
# T-007 (Windows HIP SDK installer経路の導入とCI検証 (統合)) の
# Acceptance Criteria を、test/ci/run_full_test.sh (T-004の検査ハーネス) の
# `dispatch` / `wait` / `cross-compile` サブコマンドを呼び出して検証する
# minimal-harness。run_full_test.sh 自体は変更しない。
#
# run_full_test.sh の `verify` は Linux 向けの `hipcc --version|HIP version` 判定を
# 前提にしており、Windows で `clang --version` にフォールバックした場合に
# 満たせるか不明なため、outputs / 環境変数 / hipcc・clang の検証はこのラッパー側で
# 独自に行う (dispatch した run のログを自分で取得して grep する)。
# クロスコンパイル (AC-3) の検証は OS に依存しないため run_full_test.sh の
# `cross-compile` をそのまま使う。
#
# run id のキャッシュファイル命名 (STATE_DIR/run-<os>-<version>-<method>.id) は
# run_full_test.sh と同じ規則にしているため、このスクリプトの dispatch と
# run_full_test.sh cross-compile が同じ run を共有できる (AC-3 は AC-1 の
# windows-2022 run を再利用する)。
#
# 前提 (契約。実装側と共有):
#   - .github/workflows/full-test.yml (main に登録済み) の workflow_dispatch に
#     os / version / method を渡して Windows job を起動できる。
#   - _test.yml の Windows 向け検証 step が、action の outputs / 環境変数を
#     `outputs.version=<値>` / `outputs.rocm-path=<値>` / `ROCM_PATH=<値>` の形で
#     PowerShell で1行ずつ echo し、`hipcc --version` (無ければ `clang --version`) を
#     実行する。
#   - `Cross-compile` を名前に含む step で `hipcc --offload-arch=gfx942 -c` を実行する。
#
# 使い方:
#   test/ci/run_windows_test.sh ac1   # AC-1: windows-2022 / windows-2025, version=latest
#   test/ci/run_windows_test.sh ac2   # AC-2: windows-2022, version=6.4
#   test/ci/run_windows_test.sh ac3   # AC-3: AC-1 の windows-2022 run のクロスコンパイル検証
#
# 依存: git, gh (workflow scope で認証済み)。run_full_test.sh と同じ前提を共有する。
# macOS の bash 3.2 でも動く構文 (連想配列を使わない) にしている。
#
# 実行対象の branch (feat/setup-rocm) は既に origin へ push 済みの前提。
# ここでは push を行わない (worktreeへのcommit/pushはverifierの責務外)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_FULL_TEST="${SCRIPT_DIR}/run_full_test.sh"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"

# run id (databaseId) の形式。gh run list --json databaseId は常に数値。
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_windows_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_windows_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

# run_full_test.sh の run_id_file と同じ命名規則。同じキャッシュファイルを共有することで
# このスクリプトの dispatch と run_full_test.sh の cross-compile が同じ run を指せる。
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

# run_full_test.sh dispatch を使って dispatch し、完了まで待って conclusion を検証する。
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


# キャッシュ済み run は headSha が現在の HEAD と一致するときだけ再利用する
# (別 commit の成功 run を現在の変更の証拠にしないため。dispatch 側の
# run_full_test.sh も origin/<branch> が HEAD と一致することを要求する)。
run_matches_head() {
	local id="$1" sha
	sha="$(gh run view "${id}" --json headSha --jq .headSha)"
	[ "${sha}" = "$(git -C "${REPO_ROOT}" rev-parse HEAD)" ]
}

# キャッシュされた run id があればそれを使い (完了を待ち直す)、無ければ dispatch する。
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

# AC-1 / AC-2: outputs (version / rocm-path) / 環境変数 (ROCM_PATH) /
# hipcc --version (無ければ clang --version) を検証する。
verify_windows_outputs() {
	local os="$1" version="$2" method="$3" version_regex="$4" expected_rocm_path="$5"
	local id log_file out_version out_rocm_path env_rocm_path

	id="$(get_or_dispatch_and_wait "${os}" "${version}" "${method}")"
	log_file="$(fetch_log "${id}")"

	out_version="$(grep -oE 'outputs\.version=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.version=//' | tr -d '\r')"
	out_rocm_path="$(grep -oE 'outputs\.rocm-path=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.rocm-path=//' | tr -d '\r')"
	env_rocm_path="$(grep -oE 'ROCM_PATH=.*' "${log_file}" | tail -n1 | sed -E 's/^ROCM_PATH=//' | tr -d '\r')"

	[ -n "${out_version}" ] || fail "run ${id} (os=${os}): outputs.version not found in log"
	echo "${out_version}" | grep -qE "${version_regex}" || fail "run ${id} (os=${os}): outputs.version='${out_version}' does not match ${version_regex}"

	[ "${out_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): outputs.rocm-path='${out_rocm_path}' != '${expected_rocm_path}'"
	[ "${env_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (os=${os}): ROCM_PATH='${env_rocm_path}' != '${expected_rocm_path}'"

	grep -qE 'HIP version|clang version' "${log_file}" || fail "run ${id} (os=${os}): neither 'HIP version' (hipcc --version) nor 'clang version' (clang --version) output found in log"

	log "OK for os=${os}: version=${out_version} rocm-path=${out_rocm_path}"
}

cmd_ac1() {
	verify_windows_outputs windows-2022 latest auto '^7\.2\.0$' 'C:\Program Files\AMD\ROCm\7.2'
	verify_windows_outputs windows-2025 latest auto '^7\.2\.0$' 'C:\Program Files\AMD\ROCm\7.2'
}

cmd_ac2() {
	verify_windows_outputs windows-2022 6.4 auto '^6\.4\.2$' 'C:\Program Files\AMD\ROCm\6.4'
}

cmd_ac3() {
	# AC-1 の windows-2022 (latest) run を run_full_test.sh のキャッシュ経由で再利用する。
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
