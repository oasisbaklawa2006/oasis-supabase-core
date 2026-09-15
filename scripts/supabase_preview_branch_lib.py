"""Shared helpers for governed Supabase preview branch resolution."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request

PRODUCTION_REF = "tcxvcatsqqertcnycuop"
READY_DEPLOY_STATUSES = {
    "FUNCTIONS_DEPLOYED",
    "MIGRATIONS_PASSED",
}
PENDING_DEPLOY_STATUSES = {
    "CREATING_PROJECT",
    "RUNNING_MIGRATIONS",
}
FAILED_DEPLOY_STATUSES = {
    "FUNCTIONS_FAILED",
    "MIGRATIONS_FAILED",
}
READY_PREVIEW_STATUSES = {
    "ACTIVE_HEALTHY",
    "ACTIVE_UNHEALTHY",
}


def request_json(url: str, token: str, method: str = "GET", body: dict | None = None) -> object:
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def branch_matches(branch: dict, git_branch: str, pr_number: str | None) -> bool:
    if branch.get("git_branch") != git_branch:
        return False
    if branch.get("is_default"):
        return False
    if branch.get("persistent"):
        return False
    if branch.get("parent_project_ref") != PRODUCTION_REF:
        return False
    branch_pr = branch.get("pr_number")
    if pr_number is not None and branch_pr is not None:
        try:
            if int(branch_pr) != int(pr_number):
                return False
        except (TypeError, ValueError):
            return False
    project_ref = branch.get("project_ref")
    if not isinstance(project_ref, str) or not re.fullmatch(r"[a-z0-9]{20}", project_ref):
        return False
    if project_ref == PRODUCTION_REF:
        return False
    return True


def branch_ready(branch: dict) -> bool:
    status = str(branch.get("status") or "").upper()
    preview_status = str(branch.get("preview_project_status") or "").upper()
    if status in PENDING_DEPLOY_STATUSES:
        return False
    if status in FAILED_DEPLOY_STATUSES:
        return False
    if status in READY_DEPLOY_STATUSES:
        return True
    return preview_status in READY_PREVIEW_STATUSES


def sanitize_branch_name(git_branch: str) -> str:
    candidate = re.sub(r"[^A-Za-z0-9._-]+", "-", git_branch).strip("-")
    if not candidate:
        raise ValueError("git branch name could not be sanitized for Supabase branch creation")
    return candidate[:63]
