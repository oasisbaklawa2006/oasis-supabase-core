#!/usr/bin/env bash
# Re-run the most recent failed "Core Merge Governance" workflow run for a
# given PR head SHA.
#
# Exists because that run's own bounded poll
# (scripts/check-pr-launch-relevant-check-runs.sh) can give up before a
# slow, approval-gated dependency concludes. Triggered by a workflow_run
# completion of one of that dependency's producer workflows.
#
# Deliberately does NOT re-implement, re-check out, or re-execute any of
# the governance logic itself: it only asks GitHub to redo the *original*,
# pull_request-triggered run. That run's own implicit check-run reporting
# already lands correctly on the PR head using only its own checkout (the
# PR's own code) and its own permissions (no `checks: write`, no PR-branch
# code ever running with an elevated token) -- unlike publishing a check
# run directly from here, which would require granting `checks: write` to
# a job that (on the pull_request path) also executes PR-controlled script
# content, letting that content forge the one check branch protection
# actually relies on. Re-running only needs `actions: write`, which can
# ask for genuine re-execution but cannot itself fabricate a result.
set -euo pipefail

head_sha="${HEAD_SHA:-}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
repository="${GITHUB_REPOSITORY:-}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
workflow_file="${WORKFLOW_FILE:-core-merge-governance.yml}"
max_run_attempt="${MAX_RUN_ATTEMPT:-3}"

fail() {
  echo "RERUN FAILED CORE MERGE GOVERNANCE FAILED: $*" >&2
  exit 1
}

[[ -n "$head_sha" ]] || fail 'HEAD_SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'
[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ "$max_run_attempt" =~ ^[0-9]+$ ]] || fail 'MAX_RUN_ATTEMPT must be a non-negative integer'

response="$(curl -fsS \
  --connect-timeout 15 \
  --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_base%/}/repos/${repository}/actions/workflows/${workflow_file}/runs?head_sha=${head_sha}&event=pull_request&per_page=10")" \
  || fail 'workflow run lookup failed'

selected="$(
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
runs = payload.get("workflow_runs", [])
runs.sort(key=lambda r: r.get("created_at", ""), reverse=True)
for run in runs:
    if run.get("conclusion") == "failure":
        run_id = run.get("id")
        run_attempt = run.get("run_attempt", 1)
        print(f"{run_id} {run_attempt}")
        break
' <<<"$response"
)"

if [[ -z "$selected" ]]; then
  echo "No failed Core Merge Governance run found for ${head_sha}; nothing to re-run."
  exit 0
fi

run_id="${selected%% *}"
run_attempt="${selected##* }"

if (( run_attempt >= max_run_attempt )); then
  echo "Run ${run_id} is already at attempt ${run_attempt} (max ${max_run_attempt}); not re-running again."
  exit 0
fi

curl -fsS \
  --connect-timeout 15 \
  --max-time 30 \
  -X POST \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_base%/}/repos/${repository}/actions/runs/${run_id}/rerun-failed-jobs" \
  || fail 'rerun request failed'

next_attempt=$((run_attempt + 1))
echo "Re-running failed jobs for run ${run_id} (attempt ${run_attempt} -> ${next_attempt})."
