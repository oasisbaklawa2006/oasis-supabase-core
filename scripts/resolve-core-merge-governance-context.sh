#!/usr/bin/env bash
# Resolve whether the current Core Merge Governance trigger corresponds to a
# live, open, main-targeted PR head, and which SHA/PR number/base ref to use.
#
# Exists because this workflow is triggered both by `pull_request` (the
# original path) and by `check_run: completed` (added so a slow protected
# deployment approval no longer forces this workflow's own long internal
# poll to time out before the dependency it's waiting on concludes). A
# check_run completion event can arrive for a PR head that has since moved
# on (new push during a multi-hour approval wait) -- this script re-fetches
# the PR's live head SHA from the API rather than trusting any SHA embedded
# in the triggering event, so a stale/superseded check-run completion is
# correctly treated as not relevant (the `pull_request: synchronize` trigger
# already re-runs governance for the new head on its own).
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

emit() { printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

event="${EVENT_NAME:-}"

case "$event" in
  pull_request)
    emit relevant true
    emit event_kind pull_request
    emit pr_number "${PR_NUMBER:-}"
    emit head_sha "${PR_HEAD_SHA:-}"
    emit base_ref "${PR_BASE_REF:-main}"
    exit 0
    ;;
  workflow_dispatch)
    emit relevant true
    emit event_kind workflow_dispatch
    emit pr_number ""
    emit head_sha ""
    emit base_ref "main"
    exit 0
    ;;
  check_run)
    ;;
  *)
    emit relevant false
    emit event_kind "$event"
    exit 0
    ;;
esac

# Only re-evaluate governance when one of the checks it actually depends on
# (per scripts/check-pr-launch-relevant-check-runs.sh's own required-check
# list) is what just completed -- not every check-run in the repository.
allowed_names=(
  "Static Edge Function governance"
  "Preview Edge Runtime readiness"
  "Provision encrypted preview Edge Runtime env"
  "Clean database replay and pgTAP contracts"
  "verification-primitives"
)
name="${CHECK_RUN_NAME:-}"
is_allowed=false
for allowed in "${allowed_names[@]}"; do
  if [[ "$name" == "$allowed" ]]; then
    is_allowed=true
    break
  fi
done
if [[ "$is_allowed" != true ]]; then
  emit relevant false
  emit event_kind check_run
  exit 0
fi

pr_numbers="${CHECK_RUN_PR_NUMBERS:-}"
if [[ -z "$pr_numbers" ]]; then
  emit relevant false
  emit event_kind check_run
  exit 0
fi

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
repository="${GITHUB_REPOSITORY:-}"
api_base="${GITHUB_API_URL:-https://api.github.com}"

fail() {
  echo "CORE MERGE GOVERNANCE CONTEXT RESOLUTION FAILED: $*" >&2
  exit 1
}

[[ -n "$token" ]] || fail 'GH_TOKEN is required to resolve a check_run-triggered PR context'
[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'

check_run_head_sha="${CHECK_RUN_HEAD_SHA:-}"
[[ -n "$check_run_head_sha" ]] || fail 'CHECK_RUN_HEAD_SHA is required'

resolved_pr=""
resolved_head=""
resolved_base=""

IFS=',' read -r -a pr_number_list <<<"$pr_numbers"
for num in "${pr_number_list[@]}"; do
  [[ -n "$num" ]] || continue

  response="$(curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${api_base%/}/repos/${repository}/pulls/${num}")" || continue

  live_state="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state") or "")' <<<"$response" 2>/dev/null || true)"
  live_head="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("head") or {}).get("sha") or "")' <<<"$response" 2>/dev/null || true)"
  live_base="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("base") or {}).get("ref") or "")' <<<"$response" 2>/dev/null || true)"

  [[ "$live_state" == "open" ]] || continue
  [[ -n "$live_head" ]] || continue
  [[ "$live_head" == "$check_run_head_sha" ]] || continue
  [[ "$live_base" == "main" ]] || continue

  resolved_pr="$num"
  resolved_head="$live_head"
  resolved_base="$live_base"
  break
done

if [[ -z "$resolved_pr" ]]; then
  emit relevant false
  emit event_kind check_run
  exit 0
fi

emit relevant true
emit event_kind check_run
emit pr_number "$resolved_pr"
emit head_sha "$resolved_head"
emit base_ref "$resolved_base"
