#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

before="$test_root/before.txt"
after="$test_root/after.txt"
apply_log="$test_root/apply.txt"
out_json="$test_root/provenance.json"
out_applied="$test_root/applied.json"

cat > "$before" <<'EOF'
   Local            | Remote           | Time (UTC)
  ------------------|------------------|-----------------------
   `20260826001000` | `20260826001000` | `2026-08-26 00:10:00`
   `20260826043000` | ` `              | `2026-08-26 04:30:00`
   `20260826093000` | ` `              | `2026-08-26 09:30:00`
   `20260827063731` | ` `              | `2026-08-27 06:37:31`
   `20260827090000` | ` `              | `2026-08-27 09:00:00`
   `20260827134456` | ` `              | `2026-08-27 13:44:56`
   `20260827204931` | ` `              | `2026-08-27 20:49:31`
   `20260828002000` | ` `              | `2026-08-28 00:20:00`
   `20260828002100` | ` `              | `2026-08-28 00:21:00`
EOF

cat > "$after" <<'EOF'
   Local            | Remote           | Time (UTC)
  ------------------|------------------|-----------------------
   `20260826001000` | `20260826001000` | `2026-08-26 00:10:00`
   `20260826043000` | `20260826043000` | `2026-08-26 04:30:00`
   `20260826093000` | `20260826093000` | `2026-08-26 09:30:00`
   `20260827063731` | `20260827063731` | `2026-08-27 06:37:31`
   `20260827090000` | `20260827090000` | `2026-08-27 09:00:00`
   `20260827134456` | `20260827134456` | `2026-08-27 13:44:56`
   `20260827204931` | `20260827204931` | `2026-08-27 20:49:31`
   `20260828002000` | `20260828002000` | `2026-08-28 00:20:00`
   `20260828002100` | `20260828002100` | `2026-08-28 00:21:00`
EOF

cat > "$apply_log" <<'EOF'
Applying migration 20260826043000_factory_production_role_alias_parity.sql...
Applying migration 20260826093000_3pgs_staff_provisioning_role_parity.sql...
Applying migration 20260827063731_pre_factory_so_commercial_authority.sql...
Applying migration 20260827090000_validate_pre_factory_so_commercial_origin.sql...
Applying migration 20260827134456_pre_factory_so_historical_boundary.sql...
Applying migration 20260827204931_pre_factory_pi_authority.sql...
Applying migration 20260828002000_3pgs_procurement_receipt_authority_repair.sql...
Applying migration 20260828002100_validate_3pgs_procurement_receipt_source_constraint.sql...
EOF

cd "$repo_root"
GITHUB_RUN_ID=33204321305 \
GITHUB_RUN_ATTEMPT=1 \
GITHUB_SHA="$(git rev-parse HEAD)" \
GITHUB_ACTOR=test-actor \
SUPABASE_PROJECT_REF=tcxvcatsqqertcnycuop \
  bash scripts/generate-production-migration-provenance.sh \
    "$before" "$after" "$apply_log" "$out_json" "$out_applied" >/dev/null

grep -q '"previous_production_max_version": "20260826001000"' "$out_json"
grep -q '"new_production_max_version": "20260828002100"' "$out_json"
test "$(grep -c '"version":"202608' "$out_applied")" -eq 8
for version in \
  20260826043000 20260826093000 20260827063731 20260827090000 \
  20260827134456 20260827204931 20260828002000 20260828002100; do
  grep -q "\"version\":\"$version\"" "$out_applied"
done

# Any mismatch between remote delta and the CLI's Applying-migration evidence
# must fail closed rather than emitting a misleading success artifact.
sed '/20260828002100_validate_3pgs/d' "$apply_log" > "$test_root/mismatched-apply.txt"
if bash scripts/generate-production-migration-provenance.sh \
  "$before" "$after" "$test_root/mismatched-apply.txt" \
  "$test_root/bad.json" "$test_root/bad-applied.json" >/dev/null 2>&1; then
  echo 'expected provenance generation to fail for mismatched deployment evidence' >&2
  exit 1
fi

echo 'verify-production-migration-provenance.sh: all cases passed'
