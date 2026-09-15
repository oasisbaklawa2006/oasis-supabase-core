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

load_check_conclusions() {
  local -n target_ref=$1
  local page=1
  local response page_count name conclusion

  while :; do
    response="$(curl -fsS \
      --connect-timeout 15 \
      --max-time 30 \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "${api_base%/}/repos/${repository}/commits/${head_sha}/check-runs?per_page=100&page=${page}")" \
      || fail 'GitHub check-run lookup failed'

    export PR_LAUNCH_CHECK_RUNS_JSON="$response"
    while IFS=$'\t' read -r name conclusion; do
      [[ -n "$name" ]] || continue
      target_ref["$name"]="$conclusion"
    done < <(python3 <<'PY'
import json
import os

payload = json.loads(os.environ["PR_LAUNCH_CHECK_RUNS_JSON"])
for check in payload.get("check_runs", []):
    print(f"{check.get('name', '')}\t{check.get('conclusion') or ''}")
PY
)

    page_count="$(python3 -c 'import json, os; print(len(json.loads(os.environ["PR_LAUNCH_CHECK_RUNS_JSON"]).get("check_runs", [])))')"
    if (( page_count < 100 )); then
      break
    fi
    ((page += 1))
    (( page <= 20 )) || fail 'check-run pagination exceeded safety ceiling'
  done
}

max_attempts="${PR_LAUNCH_CHECK_WAIT_ATTEMPTS:-90}"
sleep_seconds="${PR_LAUNCH_CHECK_WAIT_SECONDS:-30}"

for attempt in $(seq 1 "$max_attempts"); do
  declare -A conclusions=()
  load_check_conclusions conclusions

  pending=()
  for check_name in "${unique_required[@]}"; do
    conclusion="${conclusions[$check_name]:-}"
    if [[ -z "$conclusion" ]]; then
      pending+=("$check_name")
      continue
    fi
    if [[ "$conclusion" == "success" ]]; then
      continue
    fi
    if [[ "$conclusion" == "skipped" && "$check_name" == "Provision encrypted preview Edge Runtime env" ]]; then
      continue
    fi
    fail "required check-run ${check_name} concluded ${conclusion}; success required"
  done

  if (( ${#pending[@]} == 0 )); then
    echo "Launch-relevant PR head checks satisfied: ${unique_required[*]}"
    exit 0
  fi

  if (( attempt == max_attempts )); then
    fail "required check-runs still pending on PR head after timeout: ${pending[*]}"
  fi

  echo "Waiting for launch-relevant checks (${pending[*]}); attempt ${attempt}/${max_attempts}"
  sleep "$sleep_seconds"
done
