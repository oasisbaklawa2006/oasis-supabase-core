#!/usr/bin/env bash
# Resolve the current PR preview ref after the Supabase Preview check succeeds.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
head_sha="${GITHUB_PR_HEAD_SHA:-${GITHUB_SHA:-}}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
max_attempts="${PREVIEW_REF_WAIT_ATTEMPTS:-20}"
sleep_seconds="${PREVIEW_REF_WAIT_SECONDS:-30}"

fail() {
  echo "WAIT FOR CURRENT PR PREVIEW FAILED: $*" >&2
  exit 1
}

[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ -n "$head_sha" ]] || fail 'GITHUB_PR_HEAD_SHA or GITHUB_SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'

api="${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100"

for attempt in $(seq 1 "$max_attempts"); do
  if preview_ref="$(GITHUB_REPOSITORY="$repository" \
    GITHUB_PR_HEAD_SHA="$head_sha" \
    GH_TOKEN="$token" \
    GITHUB_API_URL="$api_base" \
    bash "$(dirname "$0")/resolve-current-pr-preview-ref.sh")"; then
    printf '%s\n' "$preview_ref"
    exit 0
  fi
  if (( attempt < max_attempts )); then
    sleep "$sleep_seconds"
  fi
done

fail 'Supabase Preview check-run did not identify exactly one successful current PR preview'
