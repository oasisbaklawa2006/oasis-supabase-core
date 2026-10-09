#!/usr/bin/env bash
# Explicitly publish the "Core merge governance validation" check run against
# a resolved PR head SHA.
#
# A workflow_run-triggered job's own implicit check-run status is reported
# against the repository's default-branch tip commit, not the triggering
# producer workflow's PR head -- documented GitHub Actions behavior, not
# something actions/checkout's `ref:` can change. Without this, a
# workflow_run re-evaluation could reach the correct conclusion and still
# never satisfy the originating PR's required status check -- the exact
# failure mode this whole repair exists to close. This script creates a
# completed check run directly on the resolved head SHA instead of relying
# on that implicit reporting.
#
# Not used for the pull_request-triggered path: that path's implicit
# check-run already lands correctly on the PR head (standard, long-proven
# GitHub Actions behavior), so publishing a duplicate there would be
# redundant, not corrective.
set -euo pipefail

head_sha="${HEAD_SHA:-}"
conclusion="${CONCLUSION:-}"
check_name="${CHECK_NAME:-Core merge governance validation}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
repository="${GITHUB_REPOSITORY:-}"
api_base="${GITHUB_API_URL:-https://api.github.com}"

fail() {
  echo "PUBLISH CORE MERGE GOVERNANCE CHECK FAILED: $*" >&2
  exit 1
}

[[ -n "$head_sha" ]] || fail 'HEAD_SHA is required'
[[ -n "$conclusion" ]] || fail 'CONCLUSION is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'
[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'

case "$conclusion" in
  success | failure | cancelled) ;;
  *) fail "unrecognized job conclusion: ${conclusion}" ;;
esac

payload="$(
  python3 -c '
import json
import sys

name, head_sha, conclusion = sys.argv[1:4]
print(json.dumps({
    "name": name,
    "head_sha": head_sha,
    "status": "completed",
    "conclusion": conclusion,
}))
' "$check_name" "$head_sha" "$conclusion"
)"

response="$(curl -fsS \
  --connect-timeout 15 \
  --max-time 30 \
  -X POST \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -d "$payload" \
  "${api_base%/}/repos/${repository}/check-runs")" || fail 'check-run creation request failed'

python3 -c '
import json
import sys

payload = json.load(sys.stdin)
check_id = payload.get("id")
if not check_id:
    sys.exit("check-run creation response missing id: " + json.dumps(payload))
conclusion = payload.get("conclusion")
head_sha = payload.get("head_sha")
print(f"Published check run {check_id} ({conclusion}) on {head_sha}")
' <<<"$response"
