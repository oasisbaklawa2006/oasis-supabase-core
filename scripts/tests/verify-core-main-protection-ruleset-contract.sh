#!/usr/bin/env bash
# Regression contract for Core Main Protection ruleset validator.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
script="$repo_root/scripts/check-core-main-protection-ruleset.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() {
  echo "CORE MAIN PROTECTION RULESET CONTRACT FAILURE: $*" >&2
  exit 1
}

# Static invariants: one independent human owner approval, not legacy 2-review policy.
grep -qF 'required_approving_review_count=1' "$script" \
  || fail 'validator must target exactly one independent human owner approval'
grep -qF 'need exactly' "$script" \
  || fail 'validator must enforce exact approval count'
if grep -qE 'min_required_approvals=2|need >= 2' "$script"; then
  fail 'validator must not retain legacy two-approval requirements'
fi

ruleset_fixture() {
  local approval_count="$1"
  python3 - "$approval_count" <<'PY'
import json
import sys

approval_count = int(sys.argv[1])
payload = {
    "name": "Core Main Protection",
    "rules": [
        {
            "type": "required_status_checks",
            "parameters": {
                "required_status_checks": [
                    {"context": "Core merge governance validation"},
                    {"context": "Migration naming, safety and contract tests"},
                    {"context": "Enforce oasis-supabase-core repo ownership boundaries"},
                    {"context": "Clean database replay and pgTAP contracts"},
                    {"context": "Static Edge Function governance"},
                    {"context": "Preview Edge Runtime readiness"},
                    {"context": "verification-primitives"},
                ]
            },
        },
        {
            "type": "pull_request",
            "parameters": {
                "required_approving_review_count": approval_count,
                "require_code_owner_review": True,
                "require_last_push_approval": True,
                "dismiss_stale_reviews_on_push": True,
                "required_review_thread_resolution": True,
                "allowed_merge_methods": ["squash"],
            },
        },
    ],
    "bypass_actors": [],
}
print(json.dumps(payload))
PY
}

run_validator() {
  local approval_count="$1"
  export CORE_MAIN_PROTECTION_RULESET_JSON
  CORE_MAIN_PROTECTION_RULESET_JSON="$(ruleset_fixture "$approval_count")"
  export GH_TOKEN='contract-test-token'
  export GITHUB_REPOSITORY='oasisbaklawa2006/oasis-supabase-core'

  mkdir -p "$test_root/bin"
  cat > "$test_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$CORE_MAIN_PROTECTION_RULESET_JSON"
CURL
  chmod +x "$test_root/bin/curl"
  PATH="$test_root/bin:$PATH" bash "$script"
}

output="$(run_validator 1)"
grep -q 'Core Main Protection ruleset matches repository target.' <<<"$output" \
  || fail 'approval_count=1 fixture must pass'

if run_validator 2 >"$test_root/pass-2.txt" 2>&1; then
  fail 'approval_count=2 fixture must fail closed'
fi
grep -q 'required_approving_review_count=2; need exactly 1' "$test_root/pass-2.txt" \
  || fail 'approval_count=2 fixture must report exact-count drift'

if run_validator 0 >"$test_root/pass-0.txt" 2>&1; then
  fail 'approval_count=0 fixture must fail closed'
fi
grep -q 'required_approving_review_count=0; need exactly 1' "$test_root/pass-0.txt" \
  || fail 'approval_count=0 fixture must report exact-count drift'

echo 'Core Main Protection ruleset contract verified (one independent human owner approval).'
