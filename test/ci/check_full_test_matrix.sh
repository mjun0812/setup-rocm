#!/usr/bin/env bash
#
# T-008 AC-1 (spec.md の「CI (全Linux / Windows job): 最小HIPソース (`__global__` kernel
# 1つ) を `hipcc --offload-arch=gfx942 -c` でコンパイルでき、GPUが無くても成功する」) の検査。
#
# 個々の経路 (package-manager / runfile / auto / container) の実 CI 検証は
# T-004〜T-007 で既に GitHub-hosted runner 上でキャッシュ済みの run により済んでいるため、
# AC-1 の「full-test の全 job にクロスコンパイル検証が含まれる」ことは実行せず静的に検査する:
#
#   (a) .github/workflows/full-test.yml が on.schedule (週次) と on.workflow_dispatch
#       (inputs os/version/method/debug を維持) の両方を持つ
#   (b) 週次 matrix (strategy.matrix を持つ job) の os に ubuntu-22.04 / ubuntu-24.04 /
#       windows-2022 / windows-2025 を、Linux 向け method に package-manager / runfile /
#       auto を含む
#   (c) その job が ./.github/workflows/_test.yml を uses している
#   (d) .github/workflows/_test.yml に、名前に "Cross-compile" を含む step が
#       Linux 用 (if: runner.os == 'Linux' 相当) と Windows 用 (if: runner.os == 'Windows'
#       相当) の両方に存在する
#
# 併せて (Done when 相当。AC には無いが static 検査のついでに検証してよい):
#   .github/workflows/release.yml が on.push.tags に `v[0-9]+.[0-9]+.[0-9]+` を持ち、
#   `vp pack` 後の dist 差分検査・`gh release create`・major tag 更新 (`git tag -fa`) の
#   step を含む
#
# 依存: python3 + PyYAML (`import yaml`)。
# 使い方: test/ci/check_full_test_matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FULL_TEST="${REPO_ROOT}/.github/workflows/full-test.yml"
TEST_YML="${REPO_ROOT}/.github/workflows/_test.yml"
RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"

fail() {
	echo "[check_full_test_matrix] FAIL: $*" >&2
	exit 1
}

[ -f "${FULL_TEST}" ] || fail "not found: ${FULL_TEST}"
[ -f "${TEST_YML}" ] || fail "not found: ${TEST_YML}"
[ -f "${RELEASE_YML}" ] || fail "not found: ${RELEASE_YML}"

python3 - "${FULL_TEST}" "${TEST_YML}" "${RELEASE_YML}" <<'PYEOF'
import sys

import yaml

full_test_path, test_yml_path, release_yml_path = sys.argv[1:4]


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def get_on(doc, filename):
    # PyYAML (YAML 1.1) parses the bare `on:` key as the boolean True key.
    on = doc.get(True)
    if on is None:
        on = doc.get("on")
    if on is None:
        fail(f"{filename}: no 'on:' key found")
    return on


full_test = load(full_test_path)
test_yml = load(test_yml_path)
release = load(release_yml_path)

# (a) on.schedule と on.workflow_dispatch (inputs os/version/method/debug) の両方
on = get_on(full_test, "full-test.yml")

if "schedule" not in on:
    fail("full-test.yml: on.schedule is missing (weekly schedule required)")
schedule = on["schedule"]
if not isinstance(schedule, list) or not schedule or "cron" not in (schedule[0] or {}):
    fail("full-test.yml: on.schedule must be a non-empty list with a 'cron' entry")

if "workflow_dispatch" not in on:
    fail("full-test.yml: on.workflow_dispatch is missing")
wd = on["workflow_dispatch"] or {}
wd_inputs = wd.get("inputs") or {}
for key in ("os", "version", "method", "debug"):
    if key not in wd_inputs:
        fail(f"full-test.yml: on.workflow_dispatch.inputs.{key} is missing")

# (b) 週次 matrix: strategy.matrix.os を持つ job を探す
jobs = full_test.get("jobs") or {}
if not jobs:
    fail("full-test.yml: no jobs found")

schedule_job_name = None
schedule_job = None
matrix = None
for name, job in jobs.items():
    strategy = job.get("strategy") or {}
    m = strategy.get("matrix") or {}
    if m.get("os"):
        schedule_job_name, schedule_job, matrix = name, job, m
        break

if schedule_job is None:
    fail("full-test.yml: no job with strategy.matrix.os found (weekly matrix)")

os_list = matrix.get("os") or []
for required_os in ("ubuntu-22.04", "ubuntu-24.04", "windows-2022", "windows-2025"):
    if required_os not in os_list:
        fail(
            f"full-test.yml: job {schedule_job_name} matrix.os is missing "
            f"{required_os} (found {os_list})"
        )

method_list = matrix.get("method") or []
for required_method in ("package-manager", "runfile", "auto"):
    if required_method not in method_list:
        fail(
            f"full-test.yml: job {schedule_job_name} matrix.method is missing "
            f"{required_method} (found {method_list})"
        )

# (c) job が ./.github/workflows/_test.yml を uses している
uses = schedule_job.get("uses")
if uses != "./.github/workflows/_test.yml":
    fail(
        f"full-test.yml: job {schedule_job_name}.uses is '{uses}', "
        "expected './.github/workflows/_test.yml'"
    )

# (d) _test.yml に Cross-compile step が Linux 用・Windows 用の両方
test_jobs = test_yml.get("jobs") or {}
cross_compile_steps = []
for jjob in test_jobs.values():
    for step in jjob.get("steps") or []:
        step_name = step.get("name")
        if isinstance(step_name, str) and "Cross-compile" in step_name:
            cross_compile_steps.append(step)

if len(cross_compile_steps) < 2:
    fail(
        "_test.yml: expected at least 2 steps with 'Cross-compile' in the name "
        f"(one Linux, one Windows), found {len(cross_compile_steps)}"
    )

linux_found = any("linux" in str(s.get("if", "")).lower() for s in cross_compile_steps)
windows_found = any("windows" in str(s.get("if", "")).lower() for s in cross_compile_steps)
if not linux_found:
    fail("_test.yml: no Cross-compile step guarded by a Linux condition (if: runner.os == 'Linux')")
if not windows_found:
    fail("_test.yml: no Cross-compile step guarded by a Windows condition (if: runner.os == 'Windows')")

# release.yml (Done when 相当。AC には無いが併せて検査する)
release_on = get_on(release, "release.yml")
push = release_on.get("push") or {}
tags = push.get("tags") or []
if "v[0-9]+.[0-9]+.[0-9]+" not in tags:
    fail(f"release.yml: on.push.tags is missing 'v[0-9]+.[0-9]+.[0-9]+' (found {tags})")

release_jobs = release.get("jobs") or {}
all_steps = []
for jjob in release_jobs.values():
    all_steps.extend(jjob.get("steps") or [])

step_runs = "\n".join(str(s.get("run", "")) for s in all_steps)

if "vp pack" not in step_runs:
    fail("release.yml: no step running 'vp pack'")
if "dist" not in step_runs:
    fail("release.yml: no step referencing 'dist' (dist freshness check)")
if "gh release create" not in step_runs:
    fail("release.yml: no step running 'gh release create'")
if "git tag -fa" not in step_runs:
    fail("release.yml: no step running 'git tag -fa' (major tag update)")

print("OK: full-test.yml weekly matrix, _test.yml Cross-compile steps, and release.yml checks passed")
PYEOF
