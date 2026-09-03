#!/usr/bin/env bash
#
# T-008 AC-2 (spec.md の「CI (ubuntu-22.04): `version: 99.9` のstepが失敗し
# (`continue-on-error` で受けて `outcome == 'failure'` を検証)、ログに「見つからない」旨と
# 取得元URLが出る」) を、実際の GitHub-hosted runner 上で検証する minimal-harness。
#
# .github/workflows/full-test.yml (workflow_dispatch: os / version / method / debug /
# expect-failure) を `gh workflow run` で expect-failure=true 付きで起動し、run のログから
# 「見つからない」旨のメッセージと取得元URLを検証する。
#
# 構造は test/ci/run_full_test.sh / test/ci/run_container_test.sh (T-004/T-005) を踏襲する
# (dispatch → run ID 特定 (数字検証) → ポーリング → ログ検証、macOS bash 3.2 対応、
# `gh workflow run` の stdout を捨てる、同時実行時の run 取り違え防止のための dispatch ロック)。
# ただし `run_full_test.sh` の `dispatch` サブコマンドは os/version/method の3つしか
# `-f` に渡せず `expect-failure` を追加できないため、dispatch は自前で行う
# (`run_full_test.sh` 自体は変更しない)。
#
# 前提 (契約。実装側と共有):
#   - .github/workflows/full-test.yml の workflow_dispatch に expect-failure
#     (boolean, default false) 入力があり、reusable workflow _test.yml へそのまま渡す。
#   - _test.yml の action step (id: setup-rocm) に
#     `continue-on-error: ${{ inputs.expect-failure }}` が付く。
#   - expect-failure=true のときは、`steps.setup-rocm.outcome == 'failure'` であることと
#     ログに未解決バージョンである旨 (`not found` を含む) と一覧の取得元URLが含まれることを
#     検証する step を実行する (このアサーションが破れたときだけ job/run を失敗させる)。
#     つまり action step 自体は continue-on-error のため、run 全体の conclusion は
#     `success` のまま完了するのが正しい状態。
#
# 使い方:
#   test/ci/run_failure_test.sh ac2   # AC-2: ubuntu-22.04, version=99.9, method=auto, expect-failure=true
#   test/ci/run_failure_test.sh dispatch <os> <version> <method>
#   test/ci/run_failure_test.sh wait <run_id>
#
# 依存: git, gh (workflow scope で認証済み)。test/ci/run_full_test.sh と同じ前提を共有する。
# macOS の bash 3.2 でも動く構文 (連想配列を使わない) にしている。
#
# 未実装の間 (RED): full-test.yml / _test.yml に expect-failure 入力が無いため、
# `gh workflow run full-test.yml ... -f expect-failure=true` が
# "Unexpected inputs" 相当のエラーで失敗する (dispatch_run の gh workflow run が非0で
# 終了し、このスクリプトも失敗する)。
#
# 実行対象の branch (feat/setup-rocm) は T-004 までの成果で既に origin へ push 済みの前提。
# ここでは push を行わない (worktree への commit/push は verifier の責務外)。
# RED 取得後、失敗 run のキャッシュ (test/ci/.state/run-ubuntu-22.04-99.9-auto.id) は
# 呼び出し元が削除すること (実装が入った後の再検証で古い run id を掴まないため)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"
WORKFLOW="full-test.yml"
BRANCH="feat/setup-rocm"

# run 完了待ちのポーリング間隔・上限 (秒)
POLL_INTERVAL="${POLL_INTERVAL:-30}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

# dispatch した run が gh run list に現れるまでの待ち (秒)
DISPATCH_WAIT_INTERVAL=3
DISPATCH_WAIT_TIMEOUT=60

# dispatch -> run id 特定 -> .state/*.id への記録 を直列化するロック。
# test/ci/run_full_test.sh と同じ workflow (full-test.yml) を dispatch するため、
# 同じロックディレクトリ名にして run_full_test.sh / run_windows_test.sh と直列化する
# (詳細は run_full_test.sh の DISPATCH_LOCK_DIR の定義を参照)。
DISPATCH_LOCK_DIR="${STATE_DIR}/.dispatch.lock"
DISPATCH_LOCK_TIMEOUT="${DISPATCH_LOCK_TIMEOUT:-120}"

# run id (databaseId) の形式。gh run list --json databaseId は常に数値。
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_failure_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_failure_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

# キャッシュキーは os-version-method (expect-failure は含めない。この harness は
# expect-failure=true 専用のため、常に同じ組み合わせでのみ dispatch する)。
run_id_file() {
	local os="$1" version="$2" method="$3" key
	key="$(printf '%s-%s-%s' "${os}" "${version}" "${method}" | tr '/: ' '___')"
	echo "${STATE_DIR}/run-${key}.id"
}

# .state/run-*.id に既に記録済みの run id 一覧 (前後に空白付きの1行) を返す。
# 同時実行中の他プロセス (run_full_test.sh 等) が既に claim した run を、
# 新たな dispatch の discovery で再び拾わないようにするための除外リストとして使う。
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

# dispatch -> run id 特定 -> .state/*.id への記録 の区間用ロック。
# mkdir はディレクトリが既に存在すると失敗するため atomic に排他できる。
acquire_dispatch_lock() {
	local waited=0
	while ! mkdir "${DISPATCH_LOCK_DIR}" 2>/dev/null; do
		waited=$((waited + 1))
		if [ "${waited}" -gt "${DISPATCH_LOCK_TIMEOUT}" ]; then
			fail "could not acquire dispatch lock (${DISPATCH_LOCK_DIR}) within ${DISPATCH_LOCK_TIMEOUT}s (stale lock from a crashed process? remove it manually if so)"
		fi
		sleep 1
	done
	# fail() 経由の異常終了でもロックを解放できるよう、取得できた時点で trap する。
	trap release_dispatch_lock EXIT
}

release_dispatch_lock() {
	rmdir "${DISPATCH_LOCK_DIR}" 2>/dev/null || true
}

# gh run list の直近5件から、before_ts より後に作られた workflow_dispatch run の
# databaseId のうち最新のものを1つ返す (無ければ空文字)。databaseId は数値のみを信頼する。
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

	# dispatch -> run id 特定 -> .state/*.id への記録 を他プロセスと排他する。
	acquire_dispatch_lock

	before_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	log "gh workflow run ${WORKFLOW} --ref ${BRANCH} -f os=${os} -f version=${version} -f method=${method} -f expect-failure=true"
	# bash の command substitution ($()) は内部の set -e を早期終了に使わないため、
	# gh workflow run 自体の失敗はここで明示的に検知して即 fail() する。
	# 標準出力は /dev/null に捨てる: 新しめの gh は成功時に run URL を stdout に返すため、
	# ここで捨てないと呼び出し元の `id="$(dispatch_run ...)"` が URL 行と
	# 本来の databaseId 行を両方まとめて捕捉してしまう。
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

	# 他プロセスの dispatch を待たせ続けないよう、記録できた時点ですぐ解放する
	# (このあとの wait_run は長時間かかるためロック範囲に含めない)。
	release_dispatch_lock

	echo "${id}"
}

get_or_dispatch_run() {
	local os="$1" version="$2" method="$3" f cached
	f="$(run_id_file "${os}" "${version}" "${method}")"
	if [ -s "${f}" ]; then
		cached="$(cat "${f}")"
		if [[ "${cached}" =~ ${RUN_ID_RE} ]]; then
			log "reusing cached run id for os=${os} version=${version} method=${method}: ${cached}"
			echo "${cached}"
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

# AC-2: version: 99.9 の action step が expect-failure=true 経由で失敗し、
# `steps.setup-rocm.outcome == 'failure'` の検証が通って run 全体は success のまま完了し、
# ログに「見つからない」旨 (not found) と取得元URル (repo.radeon.com/rocm/apt/) が出る
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

	log "AC-2 OK: run ${id} succeeded overall with expect-failure=true, and logged the not-found message and source URL"
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
