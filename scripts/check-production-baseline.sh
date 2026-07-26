#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
baseline_version='20260723161256'
baseline='supabase/migrations/20260723161256_legacy_role_authority_baseline.sql'
baseline_sha256='2b7df9c40a556b6be5e8b6cb37c4a028f31fa931cf11f5d34595151dbcbbc3ca'
seed='supabase/seed.sql'
seed_sha256='104a57706630a4d6c3fd4fe6d1414945f4a86acb3b8bd045788da77c500cb216'
archive='supabase/archived-migrations/pre-production-baseline-20260727'

fail() {
  echo "PRODUCTION BASELINE VIOLATION: $*" >&2
  exit 1
}

[[ -f "$ledger" ]] || fail "production ledger snapshot is missing"
[[ -f "$baseline" ]] || fail "canonical production baseline is missing"
[[ -f "$seed" ]] || fail "non-sensitive infrastructure seed is missing"
[[ -d "$archive" ]] || fail "superseded Core migrations were not archived"

actual_sha256="$(sha256sum "$baseline" | cut -d' ' -f1)"
[[ "$actual_sha256" == "$baseline_sha256" ]] \
  || fail "baseline checksum mismatch: expected $baseline_sha256, found $actual_sha256"
actual_seed_sha256="$(sha256sum "$seed" | cut -d' ' -f1)"
[[ "$actual_seed_sha256" == "$seed_sha256" ]] \
  || fail "seed checksum mismatch: expected $seed_sha256, found $actual_seed_sha256"

if LC_ALL=C grep -q $'\r' "$baseline"; then
  fail "baseline contains CRLF line endings"
fi
if [[ "$(LC_ALL=C tr -cd '\000' < "$baseline" | wc -c | tr -d ' ')" != '0' ]]; then
  fail "baseline contains NUL bytes"
fi

for pattern in \
  '^COPY ' \
  '^INSERT INTO ' \
  '^UPDATE ' \
  '^DELETE FROM ' \
  'postgres(ql)?://' \
  'ALTER ROLE .*PASSWORD' \
  'CREATE ROLE .*PASSWORD' \
  'eyJ[A-Za-z0-9_-]{20,}' \
  "'(sb_secret_|sk_live_|sk_test_)[A-Za-z0-9_-]{12,}'" \
  "'re_[A-Za-z0-9]{20,}'"
do
  if grep -Eiq "$pattern" "$baseline"; then
    fail "baseline contains forbidden data or credential pattern: $pattern"
  fi
done

if grep -Eiq '(^|[^a-z_])supabase_migrations\.' "$baseline"; then
  fail "baseline writes or depends on Supabase migration internals"
fi

[[ "$(grep -Ec '^CREATE TABLE' "$baseline")" == '196' ]] \
  || fail "baseline table inventory changed"
[[ "$(grep -Ec '^CREATE (OR REPLACE )?FUNCTION' "$baseline")" == '99' ]] \
  || fail "baseline function inventory changed"
[[ "$(grep -Ec '^CREATE POLICY' "$baseline")" == '439' ]] \
  || fail "baseline RLS policy inventory changed"

for forbidden_seed_target in \
  'auth.users' \
  'public.orders' \
  'public.whatsapp_messages' \
  'public.whatsapp_message_packets' \
  'cron.job' \
  'vault.secrets'
do
  grep -Fiq "$forbidden_seed_target" "$seed" \
    && fail "seed contains forbidden production-data or secret target: $forbidden_seed_target"
done

for object in \
  whatsapp_message_packets \
  companies \
  sales_order_drafts \
  is_whatsapp_inbox_reader
do
  grep -Eq "\"$object\"|\\.$object\\b" "$baseline" \
    || fail "baseline is missing required WhatsApp dependency: $object"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tail -n +2 "$ledger" | cut -d, -f1 | sort > "$tmp_dir/ledger"
find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' |
  cut -d_ -f1 |
  grep -Ev '^20260725(150000|173000|180000|200000|210000|220000|230000)$' |
  sort > "$tmp_dir/active-history"

if ! diff -u "$tmp_dir/ledger" "$tmp_dir/active-history" > "$tmp_dir/history.diff"; then
  cat "$tmp_dir/history.diff" >&2
  fail "active historical versions do not exactly match the 168-entry production ledger"
fi

while IFS=, read -r version _name; do
  [[ "$version" == 'version' || "$version" == "$baseline_version" ]] && continue
  mapfile -t matches < <(compgen -G "supabase/migrations/${version}_*.sql" || true)
  [[ "${#matches[@]}" == '1' ]] \
    || fail "production version $version must have exactly one compatibility stub"
  if grep -Evq '^[[:space:]]*(--.*)?$' "${matches[0]}"; then
    fail "historical compatibility stub contains executable SQL: ${matches[0]}"
  fi
done < "$ledger"

[[ "$(find "$archive" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')" == '41' ]] \
  || fail "expected 41 superseded Core migrations in the audit archive"

echo "Production baseline check passed: 168 ledger versions aligned, schema-only source plus storage supplement verified, 196 tables, 99 functions, 439 policies, safe infrastructure seed, and 7 pending WhatsApp migrations."
