#!/usr/bin/env python3
"""Classify trusted Supabase Preview check-runs for the current commit."""

from __future__ import annotations

import json
import sys

TRUSTED_APP_ID = 330661
TRUSTED_APP_SLUG = "supabase"
CHECK_NAME = "Supabase Preview"


def classify(payload: dict) -> str:
    matches = []
    for check in payload.get("check_runs", []):
        if check.get("name") != CHECK_NAME:
            continue
        app = check.get("app") or {}
        if app.get("id") != TRUSTED_APP_ID or app.get("slug") != TRUSTED_APP_SLUG:
            continue
        matches.append(check)

    if not matches:
        return "missing"

    terminal = [check for check in matches if check.get("status") == "completed"]
    if not terminal:
        return "pending"

    if any(check.get("conclusion") == "success" for check in terminal):
        return "success"

    if any(check.get("conclusion") == "skipped" for check in terminal):
        return "skipped"

    return "failed"


def main() -> None:
    payload = json.load(sys.stdin)
    state = classify(payload)
    print(state)
    if state == "skipped":
        print(
            "Supabase Preview was skipped for this commit. Edge Function Governance "
            "will provision a current PR preview branch through the governed "
            "Management API ensure path.",
            file=sys.stderr,
        )
        sys.exit(1)
    if state == "failed":
        print(
            "Supabase Preview completed without success for this commit.",
            file=sys.stderr,
        )
        sys.exit(1)
    if state == "missing":
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
