#!/usr/bin/env bash
# Resolve the Supabase project ref provisioned for the current PR head.
# This is deliberately fail-closed: there is no historical/default preview
# fallback and production is never an acceptable certification target.
set -euo pipefail

production_ref='tcxvcatsqqertcnycuop'
trusted_app_id='330661'
trusted_app_slug='supabase'
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

refs_file="$(mktemp)"
trap 'rm -f "$refs_file"' EXIT

page=1
while :; do
  api="${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100&page=${page}"
  response="$(curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api")" || fail 'GitHub check-run lookup failed'

  page_count="$(python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(len(payload.get("check_runs", [])))
' <<<"$response")" || fail 'GitHub check-run response was not valid JSON'

  TRUSTED_APP_ID="$trusted_app_id" TRUSTED_APP_SLUG="$trusted_app_slug" \
    python3 -c '
import json
import os
import re
import sys

trusted_id = int(os.environ["TRUSTED_APP_ID"])
trusted_slug = os.environ["TRUSTED_APP_SLUG"]
payload = json.load(sys.stdin)
for check in payload.get("check_runs", []):
    if check.get("name") != "Supabase Preview":
        continue
    if check.get("status") != "completed" or check.get("conclusion") != "success":
        continue
    app = check.get("app") or {}
    if app.get("id") != trusted_id or app.get("slug") != trusted_slug:
        continue
    url = check.get("details_url") or ""
    match = re.fullmatch(
        r"https://supabase\.com/dashboard/project/([a-z0-9]{20})/?",
        url,
    )
    if match:
        print(match.group(1))
' <<<"$response" >> "$refs_file" || fail 'Supabase Preview check-run parsing failed'

  if (( page_count < 100 )); then
    break
  fi
  ((page += 1))
  (( page <= 20 )) || fail 'GitHub check-run pagination exceeded safety ceiling'
done

mapfile -t unique_refs < <(sort -u "$refs_file" | sed '/^$/d')
(( ${#unique_refs[@]} == 1 )) \
  || fail 'Supabase Preview check-run did not identify exactly one successful current PR preview from the trusted Supabase App'
preview_ref="${unique_refs[0]}"

[[ "$preview_ref" =~ ^[a-z0-9]{20}$ ]] || fail 'resolved preview ref has invalid format'
[[ "$preview_ref" != "$production_ref" ]] || fail 'production project ref is forbidden'

printf '%s\n' "$preview_ref"
