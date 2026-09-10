#!/usr/bin/env bash
# Resolve the Supabase project ref provisioned for the current PR head.
# This is deliberately fail-closed: there is no historical/default preview
# fallback and production is never an acceptable certification target.
set -euo pipefail

production_ref='tcxvcatsqqertcnycuop'
repository="${GITHUB_REPOSITORY:-}"
head_sha="${GITHUB_PR_HEAD_SHA:-${GITHUB_SHA:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

fail() {
  echo "CURRENT PR PREVIEW RESOLUTION FAILED: $*" >&2
  exit 1
}

[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ -n "$head_sha" ]] || fail 'GITHUB_PR_HEAD_SHA or GITHUB_SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'

api="${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100"
response="$(curl -fsS \
  --connect-timeout 15 \
  --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api")" || fail 'GitHub check-run lookup failed'

preview_ref="$(python3 -c '
import json
import re
import sys

payload = json.load(sys.stdin)
refs = []
for check in payload.get("check_runs", []):
    if check.get("name") != "Supabase Preview":
        continue
    if check.get("status") != "completed" or check.get("conclusion") != "success":
        continue
    url = check.get("details_url") or ""
    match = re.fullmatch(
        r"https://supabase\.com/dashboard/project/([a-z0-9]{20})/?",
        url,
    )
    if match:
        refs.append(match.group(1))

unique_refs = sorted(set(refs))
if len(unique_refs) != 1:
    raise SystemExit("SUPABASE_PREVIEW_REF_UNRESOLVED")
print(unique_refs[0])
' <<<"$response")" || fail 'Supabase Preview check-run did not identify exactly one successful current PR preview'

[[ "$preview_ref" =~ ^[a-z0-9]{20}$ ]] || fail 'resolved preview ref has invalid format'
[[ "$preview_ref" != "$production_ref" ]] || fail 'production project ref is forbidden'

printf '%s\n' "$preview_ref"
