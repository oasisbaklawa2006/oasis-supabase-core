#!/usr/bin/env bash
# Fail closed when live GitHub ruleset "Core Main Protection" drifts from repository target.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ruleset_id='20838928'
ruleset_name='Core Main Protection'
required_checks_file='.github/rulesets/core-main-protection.required-checks.txt'
min_required_approvals=2
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
api_base="${GITHUB_API_URL:-https://api.github.com}"
repository="${GITHUB_REPOSITORY:-oasisbaklawa2006/oasis-supabase-core}"

fail() {
  echo "CORE MAIN PROTECTION RULESET DRIFT: $*" >&2
  exit 1
}

[[ -n "$token" ]] || fail 'GH_TOKEN is required'
[[ -f "$required_checks_file" ]] || fail "missing $required_checks_file"

mapfile -t expected_checks < <(grep -Ev '^(#|$)' "$required_checks_file" | sed '/^[[:space:]]*$/d')
(( ${#expected_checks[@]} > 0 )) || fail 'expected required checks list is empty'

response="$(curl -fsS \
  --connect-timeout 15 \
  --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_base%/}/repos/${repository}/rulesets/${ruleset_id}")" \
  || fail 'GitHub ruleset lookup failed'

python3 - "$ruleset_name" "$min_required_approvals" "${expected_checks[@]}" <<'PY' <<<"$response"
import json
import sys

ruleset_name = sys.argv[1]
min_required_approvals = int(sys.argv[2])
expected_checks = sys.argv[3:]
payload = json.load(sys.stdin)

if payload.get("name") != ruleset_name:
    raise SystemExit(f'name mismatch: live={payload.get("name")!r}')

rules = payload.get("rules") or []
status_rule = next((rule for rule in rules if rule.get("type") == "required_status_checks"), None)
pr_rule = next((rule for rule in rules if rule.get("type") == "pull_request"), None)
if status_rule is None:
    raise SystemExit("required_status_checks rule missing")
if pr_rule is None:
    raise SystemExit("pull_request rule missing")

live_checks = [
    item.get("context")
    for item in (status_rule.get("parameters") or {}).get("required_status_checks") or []
    if item.get("context")
]
missing = [check for check in expected_checks if check not in live_checks]
if missing:
    raise SystemExit(
        "missing required status checks on live ruleset: " + ", ".join(missing)
    )

params = pr_rule.get("parameters") or {}
approval_count = int(params.get("required_approving_review_count") or 0)
if approval_count < min_required_approvals:
    raise SystemExit(
        f"required_approving_review_count={approval_count}; need >= {min_required_approvals}"
    )
if not params.get("require_code_owner_review"):
    raise SystemExit("require_code_owner_review must be true")
if not params.get("require_last_push_approval"):
    raise SystemExit("require_last_push_approval must be true")
if params.get("allowed_merge_methods") != ["squash"]:
    raise SystemExit("allowed_merge_methods must be squash-only")

print("Core Main Protection ruleset matches repository target.")
PY
