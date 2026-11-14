#!/usr/bin/env python3
"""Fail-closed normalization of all GitHub Actions release-job attempts.

GitHub's default workflow-job listing is latest-only: a failed deployment-job
rerun can omit the already-successful preflight. Select the newest complete job
for each required name from the ALL-attempt listing, never an older successful
deployment if a newer attempt failed.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

PREFLIGHT = "WhatsApp webhook production preflight"
DEPLOY = "Approved named WhatsApp webhook deployment"
EXISTING = "Certify already-deployed WhatsApp webhook"
REQUIRED = (PREFLIGHT, DEPLOY, EXISTING)
VALID_RESULTS = frozenset(("success", "failure", "skipped", "cancelled", "timed_out", "neutral", "action_required"))


def normalize(data: dict, run_id: int, run_attempt: int) -> dict:
    if type(run_id) is not int or run_id <= 0 or type(run_attempt) is not int or run_attempt <= 0:
        raise ValueError("invalid workflow run identity")
    if not isinstance(data, dict):
        raise ValueError("workflow-job response must be an object")
    jobs = data.get("jobs")
    count = data.get("total_count")
    if not isinstance(jobs, list) or type(count) is not int or count != len(jobs) or not 3 <= count <= 100:
        raise ValueError("incomplete or unexpected workflow-job pagination; fail closed")
    versions = {}
    for job in jobs:
        if not isinstance(job, dict):
            raise ValueError("invalid job")
        name = job.get("name")
        attempt = job.get("run_attempt")
        if name not in REQUIRED or type(attempt) is not int or not 1 <= attempt <= run_attempt:
            raise ValueError("unrecognized job name or attempt")
        if job.get("run_id") != run_id:
            raise ValueError("job belongs to another workflow run")
        if job.get("status") != "completed" or job.get("conclusion") not in VALID_RESULTS:
            raise ValueError("incomplete or unknown job conclusion")
        key = (name, attempt)
        if key in versions:
            raise ValueError("ambiguous duplicate job name within one attempt")
        versions[key] = job
    newest = {}
    for name in REQUIRED:
        candidates = [job for (job_name, _), job in versions.items() if job_name == name]
        if not candidates:
            raise ValueError("missing required release job")
        newest[name] = max(candidates, key=lambda job: job["run_attempt"])
    p = newest[PREFLIGHT]["conclusion"]
    d = newest[DEPLOY]["conclusion"]
    e = newest[EXISTING]["conclusion"]
    if p != "success":
        raise ValueError("latest preflight was not successful")
    if d == "success" and e == "skipped":
        kind = "deployed"
    elif d == "skipped" and e == "skipped":
        kind = "preflight_only"
    elif d == "skipped" and e == "success":
        kind = "certify_existing_only"
    else:
        raise ValueError("ambiguous, failed or unauthorized release outcome")
    return {"kind": kind, "jobs": [newest[name] for name in REQUIRED]}


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: wa461_release_job_state.py ALL_JOBS_JSON RUN_ID RUN_ATTEMPT OUT_JSON")
    try:
        source = json.loads(Path(sys.argv[1]).read_text())
        result = normalize(source, int(sys.argv[2]), int(sys.argv[3]))
        Path(sys.argv[4]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"WA-100 release job reconciliation failed closed: {exc}") from exc
