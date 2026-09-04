#!/usr/bin/env bash
#
# T-005 (Linux RHEL系 dnf経路の導入と container CI) の
# Acceptance Criteria を、実際の GitHub Actions container job 上で検証する minimal-harness。
#
# .github/workflows/container-test.yml (workflow_dispatch: container / version / method / debug) を
# `gh workflow run` で起動し、実行中の run から action の outputs / 環境変数 /
# hipcc / クロスコンパイル結果をログと job steps から検証する。
# 構造は test/ci/run_full_test.sh (T-004) を踏襲する (dispatch → run ID 特定 (数字検証) →
# ポーリング → ログ / steps 検証、macOS bash 3.2 対応、`gh workflow run` の stdout を捨てる、
# 同時実行時の run 取り違え防止のための dispatch ロック)。
#
# 前提 (契約。実装側と共有):
#   - .github/workflows/container-test.yml に workflow_dispatch があり、
#     inputs は container (string) / version (string, default latest) / method (string, default auto)。
#     reusable workflow .github/workflows/_test-container.yml を uses: で呼ぶ。
#   - _test-container.yml の検証 step は action の outputs を
#     `outputs.version=<値>` / `outputs.rocm-path=<値>` の形で1行ずつ echo し、
#     `echo "ROCM_PATH=$ROCM_PATH"` も出す。`hipcc --version` を実行する。
#   - 最小 HIP ソース (__global__ kernel 1つ) を
#     `hipcc --offload-arch=gfx942 -c` でコンパイルする step を持ち、
#     step 名に "Cross-compile" を含む。
#
# 使い方:
#   test/ci/run_container_test.sh ac1     # AC-1: almalinux:9 / manylinux_2_28_x86_64 の outputs・環境変数・hipcc を検証
#   test/ci/run_container_test.sh ac2     # AC-2: 同じ組み合わせでクロスコンパイル (Cross-compile step) を検証
#   test/ci/run_container_test.sh dispatch <container> <version> <method>
#   test/ci/run_container_test.sh wait <run_id>
#   test/ci/run_container_test.sh verify <container> <version> <method> <version_regex> <expected_rocm_path>
#   test/ci/run_container_test.sh cross-compile <container> <version> <method>
#
# 依存: git, gh (workflow scope で認証済み)。
# macOS の bash 3.2 でも動く構文 (連想配列を使わない) にしている。
#
# 実行対象の branch (feat/setup-rocm) は T-004 までの成果で既に origin へ push 済みの前提。
# ここでは push を行わない (worktreeへのcommit/pushはverifierの責務外)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"
WORKFLOW="container-test.yml"
BRANCH="feat/setup-rocm"

# run 完了待ちのポーリング間隔・上限 (秒)
POLL_INTERVAL="${POLL_INTERVAL:-30}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

# dispatch した run が gh run list に現れるまでの待ち (秒)
DISPATCH_WAIT_INTERVAL=3
DISPATCH_WAIT_TIMEOUT=60

# dispatch -> run id 特定 -> .state/*.id への記録 を直列化するロック。
# 複数プロセスを同時に起動すると、それぞれの `gh workflow run` 直後の
# find_new_run_id が「dispatch 後に作られた最新の run」を選ぶため、
# 両方が同じ run を掴んでしまう競合が起きる。この区間を mkdir (atomic) で
# 直列化して防ぐ。test/ci/run_full_test.sh と同じロックディレクトリ名にすることで、
# 両ハーネスを同時に走らせても直列化される。
DISPATCH_LOCK_DIR="${STATE_DIR}/.dispatch.lock"
DISPATCH_LOCK_TIMEOUT="${DISPATCH_LOCK_TIMEOUT:-120}"

# run id (databaseId) の形式。gh run list --json databaseId は常に数値。
RUN_ID_RE='^[0-9]+$'

log() {
	echo "[run_container_test] $(date -u +%H:%M:%S) $*" >&2
}

fail() {
	echo "[run_container_test] ERROR: $*" >&2
	exit 1
}

mkdir -p "${STATE_DIR}"

run_id_file() {
	local container="$1" version="$2" method="$3" key
	key="$(printf '%s-%s-%s' "${container}" "${version}" "${method}" | tr '/: ' '___')"
	echo "${STATE_DIR}/run-${key}.id"
}

# .state/run-*.id に既に記録済みの run id 一覧 (前後に空白付きの1行) を返す。
# 同時実行中の他プロセスが既に claim した run を、新たな dispatch の
# discovery で再び拾わないようにするための除外リストとして使う。
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

# 検査対象の commit はローカル HEAD。dispatch は origin/${BRANCH} が HEAD と一致するときだけ行い、
# キャッシュ済み run は headSha が HEAD と一致するときだけ再利用する (古い commit の成功 run を
# 現在の変更の結果として扱わないため)。
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
	local container="$1" version="$2" method="$3"
	local before_ts id waited

	# dispatch -> run id 特定 -> .state/*.id への記録 を他プロセスと排他する。
	# (同時に複数の verify/cross-compile を走らせたときに、互いの run を
	# 取り違えないようにするための直列化。詳細は DISPATCH_LOCK_DIR の定義を参照。)
	acquire_dispatch_lock
	require_pushed_head

	before_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	log "gh workflow run ${WORKFLOW} --ref ${BRANCH} -f container=${container} -f version=${version} -f method=${method}"
	# bash の command substitution ($()) は内部の set -e を早期終了に使わないため、
	# gh workflow run 自体の失敗はここで明示的に検知して即 fail() する
	# (そうしないと後続の discovery ループが無駄に timeout まで回ってしまう)。
	# 標準出力は /dev/null に捨てる: 新しめの gh は成功時に run URL を stdout に返すため、
	# ここで捨てないと呼び出し元の `id="$(dispatch_run ...)"` が URL 行と
	# 本来の databaseId 行を両方まとめて捕捉してしまう。
	gh workflow run "${WORKFLOW}" --ref "${BRANCH}" \
		-f "container=${container}" -f "version=${version}" -f "method=${method}" \
		>/dev/null ||
		fail "gh workflow run ${WORKFLOW} failed for container=${container} version=${version} method=${method}"

	log "waiting for the dispatched run to appear in gh run list..."
	waited=0
	id=""
	while [ "${waited}" -lt "${DISPATCH_WAIT_TIMEOUT}" ]; do
		id="$(find_new_run_id "${before_ts}")"
		[ -n "${id}" ] && break
		sleep "${DISPATCH_WAIT_INTERVAL}"
		waited=$((waited + DISPATCH_WAIT_INTERVAL))
	done

	[ -n "${id}" ] || fail "could not find the dispatched run for container=${container} version=${version} method=${method} within ${DISPATCH_WAIT_TIMEOUT}s"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "dispatched run id '${id}' is not numeric (container=${container} version=${version} method=${method})"

	log "dispatched run id: ${id}"
	echo "${id}" >"$(run_id_file "${container}" "${version}" "${method}")"

	# 他プロセスの dispatch を待たせ続けないよう、記録できた時点ですぐ解放する
	# (このあとの wait_run は長時間かかるためロック範囲に含めない)。
	release_dispatch_lock

	echo "${id}"
}

get_or_dispatch_run() {
	# AC-1/AC-2 が同じ run を使い回すためのヘルパー。
	# run id のキャッシュが無ければ (または壊れていれば) 自分で dispatch する (単独実行でも動く)。
	local container="$1" version="$2" method="$3" f cached
	f="$(run_id_file "${container}" "${version}" "${method}")"
	if [ -s "${f}" ]; then
		cached="$(cat "${f}")"
		if [[ "${cached}" =~ ${RUN_ID_RE} ]]; then
			if run_matches_head "${cached}"; then
				log "reusing cached run id for container=${container} version=${version} method=${method}: ${cached}"
				echo "${cached}"
				return
			fi
			log "cached run ${cached} for container=${container} version=${version} method=${method} was built from another commit; re-dispatching"
			rm -f "${f}"
			dispatch_run "${container}" "${version}" "${method}"
			return
		fi
		log "cached run id file ${f} does not contain a plain numeric run id; ignoring and re-dispatching"
		rm -f "${f}"
	fi
	dispatch_run "${container}" "${version}" "${method}"
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

# AC-1: outputs (version / rocm-path) / 環境変数 (ROCM_PATH) / hipcc --version を検証する
verify_outputs() {
	local container="$1" version="$2" method="$3" version_regex="$4" expected_rocm_path="$5"
	local id conclusion log_file out_version out_rocm_path env_rocm_path

	id="$(get_or_dispatch_run "${container}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "verify_outputs: captured run id '${id}' is not numeric (container=${container})"

	conclusion="$(wait_run "${id}")"
	log "run ${id} (container=${container}) conclusion=${conclusion}"
	[ "${conclusion}" = "success" ] || fail "run ${id} (container=${container}) did not succeed (conclusion=${conclusion})"

	log_file="$(fetch_log "${id}")"

	out_version="$(grep -oE 'outputs\.version=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.version=//' | tr -d '\r')"
	out_rocm_path="$(grep -oE 'outputs\.rocm-path=.*' "${log_file}" | tail -n1 | sed -E 's/^outputs\.rocm-path=//' | tr -d '\r')"
	env_rocm_path="$(grep -oE 'ROCM_PATH=.*' "${log_file}" | tail -n1 | sed -E 's/^ROCM_PATH=//' | tr -d '\r')"

	[ -n "${out_version}" ] || fail "run ${id} (container=${container}): outputs.version not found in log"
	echo "${out_version}" | grep -qE "${version_regex}" || fail "run ${id} (container=${container}): outputs.version='${out_version}' does not match ${version_regex}"

	[ "${out_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (container=${container}): outputs.rocm-path='${out_rocm_path}' != '${expected_rocm_path}'"
	[ "${env_rocm_path}" = "${expected_rocm_path}" ] || fail "run ${id} (container=${container}): ROCM_PATH='${env_rocm_path}' != '${expected_rocm_path}'"

	grep -qE 'hipcc --version|HIP version' "${log_file}" || fail "run ${id} (container=${container}): hipcc --version output not found in log"

	log "AC-1 OK for container=${container}: version=${out_version} rocm-path=${out_rocm_path}"
}

# AC-2: 最小 HIP ソースのクロスコンパイル (Cross-compile step) を検証する
verify_cross_compile() {
	local container="$1" version="$2" method="$3"
	local id conclusion log_file step_conclusion

	id="$(get_or_dispatch_run "${container}" "${version}" "${method}")"
	[[ "${id}" =~ ${RUN_ID_RE} ]] || fail "verify_cross_compile: captured run id '${id}' is not numeric (container=${container})"

	conclusion="$(wait_run "${id}")"
	[ "${conclusion}" = "success" ] || fail "run ${id} (container=${container}) did not succeed (conclusion=${conclusion})"

	step_conclusion="$(gh run view "${id}" --json jobs \
		--jq '[.jobs[0].steps[] | select(.name | test("Cross-compile"; "i"))][0].conclusion // empty')"
	[ -n "${step_conclusion}" ] || fail "run ${id} (container=${container}): no step with name containing 'Cross-compile' found"
	[ "${step_conclusion}" = "success" ] || fail "run ${id} (container=${container}): Cross-compile step conclusion=${step_conclusion}"

	log_file="$(fetch_log "${id}")"
	grep -qE -- '--offload-arch=gfx942' "${log_file}" || fail "run ${id} (container=${container}): --offload-arch=gfx942 not found in log"

	log "AC-2 OK for container=${container}: Cross-compile step succeeded"
}

cmd_ac1() {
	local c
	# 両 image を先に dispatch してから待つ (GitHub 上で並列に実行させるため)。
	for c in almalinux:9 quay.io/pypa/manylinux_2_28_x86_64; do
		get_or_dispatch_run "${c}" latest package-manager >/dev/null
	done
	for c in almalinux:9 quay.io/pypa/manylinux_2_28_x86_64; do
		verify_outputs "${c}" latest package-manager '^[0-9]+\.[0-9]+\.[0-9]+$' /opt/rocm
	done
}

cmd_ac2() {
	local c
	for c in almalinux:9 quay.io/pypa/manylinux_2_28_x86_64; do
		get_or_dispatch_run "${c}" latest package-manager >/dev/null
	done
	for c in almalinux:9 quay.io/pypa/manylinux_2_28_x86_64; do
		verify_cross_compile "${c}" latest package-manager
	done
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
		echo "usage: $0 {dispatch|wait|verify|cross-compile|ac1|ac2} [args...]" >&2
		exit 2
		;;
	esac
}

main "$@"
