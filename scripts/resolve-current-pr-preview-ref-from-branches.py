#!/usr/bin/env python3
"""Resolve the current PR preview ref from Supabase branching metadata."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from supabase_preview_branch_lib import (
    PRODUCTION_REF,
    branch_matches,
    branch_ready,
    request_json,
)


def fail(message: str) -> None:
    print(f"CURRENT PR PREVIEW BRANCH RESOLUTION FAILED: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    production_ref = os.environ.get("PRODUCTION_PROJECT_REF", PRODUCTION_REF).strip()
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    git_branch = os.environ.get("GITHUB_HEAD_REF", "").strip()
    pr_number = os.environ.get("GITHUB_PR_NUMBER", "").strip() or None

    if production_ref != PRODUCTION_REF:
        fail("production project ref guard mismatch")
    if not token:
        fail("SUPABASE_ACCESS_TOKEN is required")
    if not git_branch:
        fail("GITHUB_HEAD_REF is required")

    try:
        payload = request_json(
            f"https://api.supabase.com/v1/projects/{production_ref}/branches",
            token,
        )
    except Exception as err:  # noqa: BLE001 - fail-closed resolver boundary
        fail(f"branches lookup failed: {err}")

    if not isinstance(payload, list):
        fail("branches response was not a list")

    matches = [branch for branch in payload if branch_matches(branch, git_branch, pr_number)]
    if len(matches) != 1:
        fail(
            "Supabase branching metadata did not identify exactly one current PR preview "
            f"for git branch {git_branch}"
        )

    branch = matches[0]
    if not branch_ready(branch):
        fail(
            f"matched preview branch is not ready (status={branch.get('status')}, "
            f"preview_project_status={branch.get('preview_project_status')})"
        )

    print(branch["project_ref"])


if __name__ == "__main__":
    main()
