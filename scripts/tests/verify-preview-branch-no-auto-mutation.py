#!/usr/bin/env python3
"""Offline regression: preview readiness must never mutate Supabase branches."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import pathlib
import sys
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ensure-supabase-preview-branch.py"
source_text = SOURCE.read_text()
for forbidden in ('def create_branch(', 'def branch_control_plane_recover(', 'method="POST"'):
    assert forbidden not in source_text, f"CI preview ensure is still a mutator: {forbidden}"

spec = importlib.util.spec_from_file_location("ensure_branch_under_test", SOURCE)
assert spec is not None and spec.loader is not None
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)

BRANCH = {
    "id": "preview-branch-test-id",
    "name": "fix-mc629-identity-confirmation-continuation",
    "git_branch": "fix/mc629-identity-confirmation-continuation",
    "project_ref": "oppqabaeexyacpgjjwso",
    "parent_project_ref": "tcxvcatsqqertcnycuop",
    "is_default": False,
    "persistent": False,
}
ENV = {
    "PRODUCTION_PROJECT_REF": "tcxvcatsqqertcnycuop",
    "SUPABASE_ACCESS_TOKEN": "fixture-not-real-token",
    "GITHUB_HEAD_REF": "fix/mc629-identity-confirmation-continuation",
    "GITHUB_PR_HEAD_SHA": "fixture-head",
    "GITHUB_PR_NUMBER": "412",
    "PREVIEW_BRANCH_ENSURE_ATTEMPTS": "1",
    "PREVIEW_BRANCH_ENSURE_SECONDS": "0",
}

def exercise(branch: dict | None, expected: str | None) -> None:
    branch_list = [branch] if branch is not None else []
    stderr = io.StringIO()
    stdout = io.StringIO()
    with (
        mock.patch.dict(os.environ, ENV),
        mock.patch.object(subject, "github_preview_state", return_value="skipped"),
        mock.patch.object(subject, "list_branches", return_value=branch_list),
        mock.patch.object(subject, "refresh_branch", return_value=branch),
        mock.patch.object(subject, "request_json", side_effect=AssertionError("HTTP mutation/read unexpectedly executed")),
        mock.patch.object(subject.time, "sleep", side_effect=AssertionError("unexpected retry")),
        contextlib.redirect_stdout(stdout),
        contextlib.redirect_stderr(stderr),
    ):
        if expected is None:
            subject.main()
            assert "preview branch ready" in stdout.getvalue().lower()
            return
        try:
            subject.main()
        except SystemExit as exc:
            assert exc.code == 1, (exc.code, expected)
        else:
            raise AssertionError(f"expected fail-closed: {expected}")
        assert expected in stderr.getvalue(), (expected, stderr.getvalue())

exercise(None, "PREVIEW_NOT_PROVISIONED")
exercise(dict(BRANCH, status="MIGRATIONS_FAILED"), "PREVIEW_BRANCH_NOT_READY")
exercise(dict(BRANCH, status="FUNCTIONS_FAILED"), "PREVIEW_BRANCH_NOT_READY")
exercise(dict(BRANCH, status="CREATING_PROJECT"), "did not become ready within the ensure window")
exercise(dict(BRANCH, status="FUNCTIONS_DEPLOYED", preview_project_status="ACTIVE_HEALTHY"), None)
print("Preview ensure regression PASS: no create/rebase/reset; known failure halts; existing ready branch accepted.")
