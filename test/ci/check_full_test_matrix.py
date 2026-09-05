#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""Static check that every full-test job verifies a HIP cross-compile.

The per-route installs are verified on real GitHub-hosted runners by the
other harnesses under test/ci/. This script checks statically that:

  (a) .github/workflows/full-test.yml has both on.schedule (weekly) and
      on.workflow_dispatch with the os/version/method/debug inputs
  (b) the weekly matrix job covers ubuntu-22.04 / ubuntu-24.04 /
      windows-2022 / windows-2025 and the package-manager / runfile / auto
      methods
  (c) that job uses ./.github/workflows/_test.yml
  (d) .github/workflows/_test.yml has a "Cross-compile" step for Linux and
      one for Windows

and, as a companion check, that .github/workflows/release.yml triggers on
v[0-9]+.[0-9]+.[0-9]+ tags, verifies dist/ freshness after `vp pack`,
creates the GitHub release, and updates the major tag.

Usage: test/ci/check_full_test_matrix.py (run through uv, see the shebang)
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, NoReturn

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
FULL_TEST = REPO_ROOT / ".github" / "workflows" / "full-test.yml"
TEST_YML = REPO_ROOT / ".github" / "workflows" / "_test.yml"
RELEASE_YML = REPO_ROOT / ".github" / "workflows" / "release.yml"

REQUIRED_OS = ("ubuntu-22.04", "ubuntu-24.04", "windows-2022", "windows-2025")
REQUIRED_METHODS = ("package-manager", "runfile", "auto")
REQUIRED_DISPATCH_INPUTS = ("os", "version", "method", "debug")
RELEASE_TAG_PATTERN = "v[0-9]+.[0-9]+.[0-9]+"

# YAML 1.1 turns the bare `on:` key into the boolean True, so keys are not always str.
Workflow = dict[Any, Any]


def fail(message: str) -> NoReturn:
    """Print a failure message and exit with status 1.

    Args:
        message: Description of the failed check.
    """
    print(f"[check_full_test_matrix] FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def load(path: Path) -> Workflow:
    """Load a workflow YAML file.

    Args:
        path: Path to the workflow file.

    Returns:
        The parsed workflow document.
    """
    if not path.is_file():
        fail(f"not found: {path}")
    with path.open() as f:
        return yaml.safe_load(f)


def get_on(doc: Workflow, filename: str) -> Workflow:
    """Return the `on:` trigger mapping of a workflow document.

    PyYAML (YAML 1.1) parses the bare `on:` key as the boolean True, so both
    spellings are accepted.

    Args:
        doc: The parsed workflow document.
        filename: Workflow file name used in failure messages.

    Returns:
        The trigger mapping.
    """
    on = doc.get(True)
    if on is None:
        on = doc.get("on")
    if on is None:
        fail(f"{filename}: no 'on:' key found")
    return on


def check_full_test_triggers(full_test: Workflow) -> None:
    """Check that full-test.yml has the weekly schedule and the dispatch inputs.

    Args:
        full_test: The parsed full-test.yml document.
    """
    on = get_on(full_test, "full-test.yml")

    schedule = on.get("schedule")
    if schedule is None:
        fail("full-test.yml: on.schedule is missing (weekly schedule required)")
    if (
        not isinstance(schedule, list)
        or not schedule
        or "cron" not in (schedule[0] or {})
    ):
        fail("full-test.yml: on.schedule must be a non-empty list with a 'cron' entry")

    if "workflow_dispatch" not in on:
        fail("full-test.yml: on.workflow_dispatch is missing")
    inputs = (on["workflow_dispatch"] or {}).get("inputs") or {}
    for key in REQUIRED_DISPATCH_INPUTS:
        if key not in inputs:
            fail(f"full-test.yml: on.workflow_dispatch.inputs.{key} is missing")


def find_matrix_job(full_test: Workflow) -> tuple[str, Workflow, Workflow]:
    """Find the job that carries the weekly OS matrix.

    Args:
        full_test: The parsed full-test.yml document.

    Returns:
        The job name, the job mapping, and its strategy matrix.
    """
    jobs = full_test.get("jobs") or {}
    if not jobs:
        fail("full-test.yml: no jobs found")
    for name, job in jobs.items():
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        if matrix.get("os"):
            return name, job, matrix
    fail("full-test.yml: no job with strategy.matrix.os found (weekly matrix)")


def check_full_test_matrix(full_test: Workflow) -> None:
    """Check that the weekly matrix covers every OS and method via _test.yml.

    Args:
        full_test: The parsed full-test.yml document.
    """
    name, job, matrix = find_matrix_job(full_test)

    os_list = matrix.get("os") or []
    for required_os in REQUIRED_OS:
        if required_os not in os_list:
            fail(
                f"full-test.yml: job {name} matrix.os is missing {required_os} (found {os_list})"
            )

    method_list = matrix.get("method") or []
    for required_method in REQUIRED_METHODS:
        if required_method not in method_list:
            fail(
                f"full-test.yml: job {name} matrix.method is missing {required_method} "
                f"(found {method_list})"
            )

    uses = job.get("uses")
    if uses != "./.github/workflows/_test.yml":
        fail(
            f"full-test.yml: job {name}.uses is '{uses}', expected './.github/workflows/_test.yml'"
        )


def check_cross_compile_steps(test_yml: Workflow) -> None:
    """Check that _test.yml has a Cross-compile step for Linux and for Windows.

    Args:
        test_yml: The parsed _test.yml document.
    """
    steps = [
        step
        for job in (test_yml.get("jobs") or {}).values()
        for step in job.get("steps") or []
        if isinstance(step.get("name"), str) and "Cross-compile" in step["name"]
    ]
    if len(steps) < 2:
        fail(
            "_test.yml: expected at least 2 steps with 'Cross-compile' in the name "
            f"(one Linux, one Windows), found {len(steps)}"
        )

    conditions = [str(step.get("if", "")).lower() for step in steps]
    if not any("linux" in condition for condition in conditions):
        fail(
            "_test.yml: no Cross-compile step guarded by a Linux condition (if: runner.os == 'Linux')"
        )
    if not any("windows" in condition for condition in conditions):
        fail(
            "_test.yml: no Cross-compile step guarded by a Windows condition (if: runner.os == 'Windows')"
        )


def check_release(release: Workflow) -> None:
    """Check the release workflow's tag trigger and its release steps.

    Args:
        release: The parsed release.yml document.
    """
    tags = (get_on(release, "release.yml").get("push") or {}).get("tags") or []
    if RELEASE_TAG_PATTERN not in tags:
        fail(
            f"release.yml: on.push.tags is missing '{RELEASE_TAG_PATTERN}' (found {tags})"
        )

    runs = "\n".join(
        str(step.get("run", ""))
        for job in (release.get("jobs") or {}).values()
        for step in job.get("steps") or []
    )
    for needle, description in (
        ("vp pack", "no step running 'vp pack'"),
        ("dist", "no step referencing 'dist' (dist freshness check)"),
        ("gh release create", "no step running 'gh release create'"),
        ("git tag -fa", "no step running 'git tag -fa' (major tag update)"),
    ):
        if needle not in runs:
            fail(f"release.yml: {description}")


def main() -> None:
    """Run all checks and print a summary line on success."""
    full_test = load(FULL_TEST)
    test_yml = load(TEST_YML)
    release = load(RELEASE_YML)

    check_full_test_triggers(full_test)
    check_full_test_matrix(full_test)
    check_cross_compile_steps(test_yml)
    check_release(release)

    print(
        "OK: full-test.yml weekly matrix, _test.yml Cross-compile steps, and release.yml checks passed"
    )


if __name__ == "__main__":
    main()
