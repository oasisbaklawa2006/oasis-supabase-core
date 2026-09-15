#!/usr/bin/env bash
# Resolve the current PR preview ref after the Supabase Preview check succeeds.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
head_sha="${GITHUB_PR_HEAD_SHA:-${GITHUB_SHA:-}}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
max_attempts="${PREVIEW_REF_WAIT_ATTEMPTS:-20}"
sleep_seconds="${PREVIEW_REF_WAIT_SECONDS:-30}"
trusted_app_id='330661'
trusted_app_slug='supabase'

fail() {
  echo "WAIT FOR CURRENT PR PREVIEW FAILED: $*" >&2
  exit 1
}

[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ -n "$head_sha" ]] || fail 'GITHUB_PR_HEAD_SHA or GITHUB_SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'

api="${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100"

preview_terminal_conclusion() {
  local response
  response="$(curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api")" || fail 'GitHub check-run lookup failed while classifying preview state'

  TRUSTED_APP_ID="$trusted_app_id" TRUSTED_APP_SLUG="$trusted_app_slug" \
    python3 -c '
import json
import os
import sys

trusted_id = int(os.environ["TRUSTED_APP_ID"])
trusted_slug = os.environ["TRUSTED_APP_SLUG"]
payload = json.load(sys.stdin)
checks = []
for check in payload.get("check_runs", []):
    if check.get("name") != "Supabase Preview":
        continue
    app = check.get("app") or {}
    if app.get("id") != trusted_id or app.get("slug") != trusted_slug:
        continue
    checks.append(check)

completed_checks = [check for check in checks if check.get("status") == "completed"]
if not completed_checks:
    raise SystemExit(0)

latest = max(completed_checks, key=lambda check: int(check.get("id") or 0))
conclusion = latest.get("conclusion") or ""
if conclusion and conclusion != "success":
    print(conclusion)
' <<<"$response" || fail 'Supabase Preview check-run state parsing failed'
}

for attempt in $(seq 1 "$max_attempts"); do
  if preview_ref="$(GITHUB_REPOSITORY="$repository" \
    GITHUB_PR_HEAD_SHA="$head_sha" \
    GH_TOKEN="$token" \
    GITHUB_API_URL="$api_base" \
    bash "$(dirname "$0")/resolve-current-pr-preview-ref.sh")"; then
    printf '%s\n' "$preview_ref"
    exit 0
  fi

  terminal_conclusion="$(preview_terminal_conclusion)"
  if [[ "$terminal_conclusion" == 'skipped' ]]; then
    fail 'PREVIEW_NOT_PROVISIONED: trusted Supabase Preview check-run completed as skipped'
  fi
  if [[ -n "$terminal_conclusion" ]]; then
    fail "PREVIEW_TERMINAL_STATE: trusted Supabase Preview check-run completed as ${terminal_conclusion}"
  fi

  if (( attempt < max_attempts )); then
    sleep "$sleep_seconds"
  fi
done

fail 'Supabase Preview check-run did not identify exactly one successful current PR preview'
