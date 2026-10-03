#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-migration-governance.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

init_fixture() {
  local dir="$1"
  mkdir -p "$dir/supabase/migrations" "$dir/docs/reconciliation" "$dir/scripts"
  cp "$checker" "$dir/scripts/check-migration-governance.sh"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name 'Migration Governance Regression Test'
  git -C "$dir" config user.email 'migration-governance@example.invalid'
  printf '%s\n' '-- activation base' > "$dir/supabase/migrations/20261001000000_activation_base.sql"
  printf '%s\n' 'canonical_version,status,replacement_version,remote_evidence,evidence'     > "$dir/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
  git -C "$dir" add .
  git -C "$dir" commit -q -m activation
  git -C "$dir" rev-parse HEAD
}

# A reconciled historical migration is represented in the canonical lineage
# ledger but has no feature contract test. The governance checker must exempt it
# from pending-migration contract rules while retaining filename and safety checks.
represented="$test_root/represented-remote"
represented_base="$(init_fixture "$represented")"
printf '%s\n'   '20261001233000,represented_remote,,read-only-production-catalog-20261002,reconciled historical state'   >> "$represented/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
printf '%s\n' '-- historical SQL retained for replay lineage only'   > "$represented/supabase/migrations/20261001233000_b2b_reapply_after_rejection.sql"
git -C "$represented" add .
git -C "$represented" commit -q -m represented-remote
(cd "$represented" && bash scripts/check-migration-governance.sh "$represented_base") > "$represented/check.out"
grep -q '^Migration governance check passed:' "$represented/check.out"

# A normal forward migration without a matching SQL contract test must still fail.
pending="$test_root/pending-forward"
pending_base="$(init_fixture "$pending")"
printf '%s\n' '-- pending forward SQL'   > "$pending/supabase/migrations/20261002183100_customer_checkout_snapshot_origin_immutability.sql"
git -C "$pending" add .
git -C "$pending" commit -q -m pending-forward
if (cd "$pending" && bash scripts/check-migration-governance.sh "$pending_base") > "$pending/check.out" 2>&1; then
  echo 'Expected an untested pending migration to fail governance' >&2
  exit 1
fi
grep -q 'has no SQL contract test referencing migration version or name' "$pending/check.out"

echo 'Represented-remote migration governance regression passed.'
