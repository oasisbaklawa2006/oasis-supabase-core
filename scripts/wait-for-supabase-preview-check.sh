#!/usr/bin/env bash
# Wait until the trusted Supabase Preview check succeeds for a commit SHA.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
head_sha="${1:-${GITHUB_PR_HEAD_SHA:-${GITHUB_SHA:-}}}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
max_attempts="${PREVIEW_CHECK_WAIT_ATTEMPTS:-20}"
sleep_seconds="${PREVIEW_CHECK_WAIT_SECONDS:-30}"

fail() {
  echo "WAIT FOR SUPABASE PREVIEW FAILED: $*" >&2
  exit 1
}

[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ -n "$head_sha" ]] || fail 'commit SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'

for attempt in $(seq 1 "$max_attempts"); do
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

    if python3 "$(dirname "$0")/check-supabase-preview-success.py" <<<"$response"; then
      echo "Supabase Preview redeploy succeeded for ${head_sha}"
      exit 0
    fi

    page_count="$(python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(len(payload.get("check_runs", [])))
' <<<"$response")" || fail 'GitHub check-run response was not valid JSON'
    if (( page_count < 100 )); then
      break
    fi
    ((page += 1))
    (( page <= 20 )) || fail 'GitHub check-run pagination exceeded safety ceiling'
  done

  if (( attempt < max_attempts )); then
    sleep "$sleep_seconds"
  fi
done

fail 'trusted Supabase Preview check-run did not succeed'
