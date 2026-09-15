#!/usr/bin/env bash
# When a PR touches launch-relevant Core paths, require successful head check-runs.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
head_sha="${GITHUB_PR_HEAD_SHA:-${GITHUB_SHA:-}}"
base_ref="${GITHUB_BASE_REF:-main}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"

fail() {
  echo "PR LAUNCH-RELEVANT CHECK FAILURE: $*" >&2
  exit 1
}

[[ -n "$repository" ]] || fail 'GITHUB_REPOSITORY is required'
[[ -n "$head_sha" ]] || fail 'GITHUB_PR_HEAD_SHA or GITHUB_SHA is required'
[[ -n "$token" ]] || fail 'GH_TOKEN is required'

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail 'git worktree required to inspect changed paths'
fi

mapfile -t changed_files < <(git diff --name-only "origin/${base_ref}"...HEAD 2>/dev/null || git diff --name-only "${base_ref}"...HEAD)
(( ${#changed_files[@]} > 0 )) || changed_files=()

needs="$(python3 - "${changed_files[@]}" <<'PY'
import sys
changed = sys.argv[1:]
edge_prefixes = (
    "supabase/functions/",
    "supabase/config.toml",
    "scripts/check-edge-",
    "scripts/check-whatsapp-",
    "scripts/resolve-current-pr-preview-ref.sh",
    "scripts/wait-for-current-pr-preview-ref.sh",
    "scripts/wait-for-supabase-preview-check.sh",
    ".github/workflows/edge-function-governance.yml",
    ".github/workflows/whatsapp-webhook-security.yml",
)
migration_prefixes = (
    "supabase/migrations/",
    "supabase/tests/",
    "supabase/archived-migrations/",
)
needs_edge = any(path.startswith(p) for path in changed for p in edge_prefixes)
needs_migration = any(path.startswith(p) for path in changed for p in migration_prefixes)
if needs_edge:
    print("edge")
if needs_migration:
    print("migration")
PY
)" || true

if [[ -z "$needs" ]]; then
  echo "PR does not touch launch-relevant paths; launch check-run enforcement skipped."
  exit 0
fi

required_checks=()
if grep -qx edge <<<"$needs"; then
  required_checks+=(
    "Static Edge Function governance"
    "Preview Edge Runtime readiness"
    "Provision encrypted preview Edge Runtime env"
  )
fi
if grep -qx migration <<<"$needs"; then
  required_checks+=("Clean database replay and pgTAP contracts")
fi
if printf '%s\n' "${changed_files[@]}" | grep -Eq '^(supabase/functions/whatsapp-webhook/|supabase/functions/_shared/whatsappWebhook|\.github/workflows/whatsapp-webhook-security\.yml)'; then
  required_checks+=("verification-primitives")
fi

mapfile -t unique_required < <(printf '%s\n' "${required_checks[@]}" | sort -u)

page=1
declare -A conclusions=()
while :; do
  api="${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100&page=${page}"
  response="$(curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api")" || fail 'GitHub check-run lookup failed'

  while IFS=$'\t' read -r name conclusion; do
    [[ -n "$name" ]] || continue
    conclusions["$name"]="$conclusion"
  done < <(python3 -c '
import json, sys
payload = json.load(sys.stdin)
for check in payload.get("check_runs", []):
    print(f"{check.get('name','')}\t{check.get('conclusion') or ''}")
' <<<"$response")

  page_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("check_runs", [])))' <<<"$response")"
  if (( page_count < 100 )); then
    break
  fi
  ((page += 1))
  (( page <= 20 )) || fail 'check-run pagination exceeded safety ceiling'
done

for check_name in "${unique_required[@]}"; do
  conclusion="${conclusions[$check_name]:-}"
  if [[ -z "$conclusion" ]]; then
    fail "required check-run missing on PR head: ${check_name}"
  fi
  if [[ "$conclusion" != "success" ]]; then
    fail "required check-run ${check_name} concluded ${conclusion}; success required"
  fi
done

echo "Launch-relevant PR head checks satisfied: ${unique_required[*]}"
