#!/usr/bin/env python3
"""Ensure a current PR preview branch exists when GitHub Preview was skipped."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from supabase_preview_branch_lib import (
    PRODUCTION_REF,
    branch_matches,
    branch_ready,
    request_json,
    sanitize_branch_name,
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CLASSIFY = os.path.join(SCRIPT_DIR, "classify-supabase-preview-check.py")


def fail(message: str) -> None:
    print(f"ENSURE SUPABASE PREVIEW BRANCH FAILED: {message}", file=sys.stderr)
    sys.exit(1)


def github_preview_state(head_sha: str) -> str:
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    token = os.environ.get("GH_TOKEN", os.environ.get("GITHUB_TOKEN", "")).strip()
    api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    if not repository or not token or not head_sha:
        return "missing"

    url = f"{api_base}/repos/{repository}/commits/{head_sha}/check-runs?per_page=100"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError:
        return "missing"

    proc = subprocess.run(
        [sys.executable, CLASSIFY],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )
    state = (proc.stdout or "").strip().splitlines()[0] if proc.stdout else "missing"
    return state or "missing"


def list_branches(token: str, production_ref: str) -> list[dict]:
    payload = request_json(
        f"https://api.supabase.com/v1/projects/{production_ref}/branches",
        token,
    )
    if not isinstance(payload, list):
        fail("branches response was not a list")
    return payload


def create_branch(token: str, production_ref: str, git_branch: str) -> dict:
    body = {
        "branch_name": sanitize_branch_name(git_branch),
        "git_branch": git_branch,
        "persistent": False,
    }
    payload = request_json(
        f"https://api.supabase.com/v1/projects/{production_ref}/branches",
        token,
        method="POST",
        body=body,
    )
    if not isinstance(payload, dict):
        fail("branch creation response was not an object")
    return payload


def main() -> None:
    production_ref = os.environ.get("PRODUCTION_PROJECT_REF", PRODUCTION_REF).strip()
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    git_branch = os.environ.get("GITHUB_HEAD_REF", "").strip()
    head_sha = os.environ.get("GITHUB_PR_HEAD_SHA", os.environ.get("GITHUB_SHA", "")).strip()
    pr_number = os.environ.get("GITHUB_PR_NUMBER", "").strip() or None
    max_attempts = int(os.environ.get("PREVIEW_BRANCH_ENSURE_ATTEMPTS", "20"))
    sleep_seconds = int(os.environ.get("PREVIEW_BRANCH_ENSURE_SECONDS", "30"))

    if production_ref != PRODUCTION_REF:
        fail("production project ref guard mismatch")
    if not token:
        fail("SUPABASE_ACCESS_TOKEN is required")
    if not git_branch:
        fail("GITHUB_HEAD_REF is required")
    if not head_sha:
        fail("GITHUB_PR_HEAD_SHA or GITHUB_SHA is required")

    preview_state = github_preview_state(head_sha)
    if preview_state == "success":
        print(f"Supabase Preview already succeeded for {head_sha}")
        return

    if preview_state not in {"skipped", "missing", "pending", "failed"}:
        fail(f"unexpected Supabase Preview state: {preview_state}")

    branches = list_branches(token, production_ref)
    matches = [branch for branch in branches if branch_matches(branch, git_branch, pr_number)]
    if not matches:
        print(
            f"Creating Supabase preview branch for git branch {git_branch} "
            f"because GitHub Preview state is {preview_state}",
            file=sys.stderr,
        )
        create_branch(token, production_ref, git_branch)

    for attempt in range(1, max_attempts + 1):
        branches = list_branches(token, production_ref)
        matches = [branch for branch in branches if branch_matches(branch, git_branch, pr_number)]
        if len(matches) == 1 and branch_ready(matches[0]):
            project_ref = matches[0]["project_ref"]
            print(
                f"Supabase preview branch ready for {git_branch}: {project_ref} "
                f"(status={matches[0].get('status')})"
            )
            return
        if attempt < max_attempts:
            time.sleep(sleep_seconds)

    fail(f"preview branch for {git_branch} did not become ready within the ensure window")


if __name__ == "__main__":
    main()
