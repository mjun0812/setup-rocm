#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""Regression test for check_full_test_matrix.py's `pip` requirement.

T-007 AC-1 (spec.md: 週次 matrix の Linux method から `pip` を外すと静的検査
(test/ci/check_full_test_matrix.py) が失敗する) の検査。check_full_test_matrix.py
自体は変更しない (実装は full-test.yml の matrix.method と
check_full_test_matrix.py の REQUIRED_METHODS に `pip` を加える側の責務)。

check_full_test_matrix.py は `Path(__file__).resolve().parents[2]` で repo root
を求めるため、workflow だけを差し替えることはできない。そこで
check_full_test_matrix.py と .github/workflows/*.yml を repo-root と同じ形の
一時ディレクトリへコピーし、コピー側の full-test.yml だけを書き換えて検査する。

Checks:
  1. the real repo (unmodified) passes: `uv run check_full_test_matrix.py` exits 0
  2. a copy with `pip` removed from the weekly matrix.method fails: exits non-zero

Usage: test/ci/check_full_test_matrix_test.py (run through uv, see the shebang)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK_SCRIPT = REPO_ROOT / "test" / "ci" / "check_full_test_matrix.py"
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
WORKFLOW_FILES = ("full-test.yml", "_test.yml", "release.yml")


def fail(message: str) -> None:
    """Print a failure message and exit with status 1.

    Args:
        message: Description of the failed check.
    """
    print(f"[check_full_test_matrix_test] FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def run_check(repo_root: Path) -> subprocess.CompletedProcess[str]:
    """Run check_full_test_matrix.py against a repo-root-shaped directory.

    Args:
        repo_root: Directory laid out like a repo root, containing
            test/ci/check_full_test_matrix.py and .github/workflows/*.yml.

    Returns:
        The completed subprocess, with stdout/stderr captured as text.
    """
    script = repo_root / "test" / "ci" / "check_full_test_matrix.py"
    return subprocess.run(
        ["uv", "run", str(script)],
        capture_output=True,
        text=True,
    )


def build_repo_without_pip(tmp_root: Path) -> None:
    """Populate a repo-root-shaped copy with `pip` removed from the weekly matrix.

    Copies test/ci/check_full_test_matrix.py and .github/workflows/*.yml into
    tmp_root (so the copied script's own `parents[2]` still resolves to
    tmp_root), then removes "pip" from the weekly job's
    strategy.matrix.method list in the copied full-test.yml.

    Args:
        tmp_root: Empty directory to populate.
    """
    (tmp_root / "test" / "ci").mkdir(parents=True)
    shutil.copy(CHECK_SCRIPT, tmp_root / "test" / "ci" / CHECK_SCRIPT.name)

    dst_workflows = tmp_root / ".github" / "workflows"
    dst_workflows.mkdir(parents=True)
    for name in WORKFLOW_FILES:
        shutil.copy(WORKFLOWS_DIR / name, dst_workflows / name)

    full_test_path = dst_workflows / "full-test.yml"
    doc: dict[Any, Any] = yaml.safe_load(full_test_path.read_text())
    for job in (doc.get("jobs") or {}).values():
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        method = matrix.get("method")
        if isinstance(method, list) and "pip" in method:
            method.remove("pip")
    full_test_path.write_text(yaml.safe_dump(doc, sort_keys=False))


def main() -> None:
    """Run both scenarios and print a summary line on success."""
    real_result = run_check(REPO_ROOT)
    if real_result.returncode != 0:
        fail(
            "check_full_test_matrix.py exited "
            f"{real_result.returncode} against the real full-test.yml\n"
            f"{real_result.stdout}{real_result.stderr}"
        )

    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        build_repo_without_pip(tmp_root)
        without_pip_result = run_check(tmp_root)
        if without_pip_result.returncode == 0:
            fail(
                "check_full_test_matrix.py exited 0 against a full-test.yml "
                "with 'pip' removed from the weekly matrix.method "
                "(expected a non-zero exit)"
            )

    print("OK: check_full_test_matrix.py requires 'pip' in the weekly matrix.method")


if __name__ == "__main__":
    main()
