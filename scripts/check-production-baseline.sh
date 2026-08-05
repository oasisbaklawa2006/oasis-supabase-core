#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

baseline_ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
post_baseline_ledger='docs/reconciliation/production-migration-ledger-post-baseline-2026-07-27.csv'
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

[[ -f "$baseline_ledger" ]] || fail "immutable production baseline ledger is missing"
[[ -f "$post_baseline_ledger" ]] || fail "post-baseline production ledger is missing"
[[ -f "$baseline" ]] || fail "canonical production baseline is missing"
[[ -f "$seed" ]] || fail "non-sensitive infrastructure seed is missing"
[[ -d "$archive" ]] || fail "superseded Core migrations were not archived"

actual_sha256="$(sha256sum "$baseline" | cut -d' ' -f1)"
[[ "$actual_sha256" == "$baseline_sha256" ]] || fail "baseline checksum mismatch: expected $baseline_sha256, found $actual_sha256"
actual_seed_sha256="$(sha256sum "$seed" | cut -d' ' -f1)"
[[ "$actual_seed_sha256" == "$seed_sha256" ]] || fail "seed checksum mismatch: expected $seed_sha256, found $actual_seed_sha256"

if LC_ALL=C grep -q $'\r' "$baseline"; then fail "baseline contains CRLF line endings"; fi
if [[ "$(LC_ALL=C tr -cd '\000' < "$baseline" | wc -c | tr -d ' ')" != '0' ]]; then fail "baseline contains NUL bytes"; fi

for pattern in '^COPY ' '^INSERT INTO ' '^UPDATE ' '^DELETE FROM ' 'postgres(ql)?://' 'ALTER ROLE .*PASSWORD' 'CREATE ROLE .*PASSWORD' 'eyJ[A-Za-z0-9_-]{20,}' "'(sb_secret_|sk_live_|sk_test_)[A-Za-z0-9_-]{12,}'" "'re_[A-Za-z0-9]{20,}'"; do
  if grep -Eiq "$pattern" "$baseline"; then fail "baseline contains forbidden data or credential pattern: $pattern"; fi
done

if grep -Eiq '(^|[^a-z_])supabase_migrations\.' "$baseline"; then fail "baseline writes or depends on Supabase migration internals"; fi

[[ "$(grep -Ec '^CREATE TABLE' "$baseline")" == '196' ]] || fail "baseline table inventory changed"
[[ "$(grep -Ec '^CREATE (OR REPLACE )?FUNCTION' "$baseline")" == '99' ]] || fail "baseline function inventory changed"
[[ "$(grep -Ec '^CREATE POLICY' "$baseline")" == '439' ]] || fail "baseline RLS policy inventory changed"

for forbidden_seed_target in 'auth.users' 'public.orders' 'public.whatsapp_messages' 'public.whatsapp_message_packets' 'cron.job' 'vault.secrets'; do
  grep -Fiq "$forbidden_seed_target" "$seed" && fail "seed contains forbidden production-data or secret target: $forbidden_seed_target"
done

for object in whatsapp_message_packets companies sales_order_drafts is_whatsapp_inbox_reader; do
  grep -Eq "\"$object\"|\\.$object\\b" "$baseline" || fail "baseline is missing required WhatsApp dependency: $object"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tail -n +2 "$baseline_ledger" | cut -d, -f1 | sort > "$tmp_dir/baseline-ledger"
tail -n +2 "$post_baseline_ledger" | cut -d, -f1 | sort > "$tmp_dir/post-baseline-ledger"
cat "$tmp_dir/baseline-ledger" "$tmp_dir/post-baseline-ledger" | sort > "$tmp_dir/current-ledger"
find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | cut -d_ -f1 | sort > "$tmp_dir/active-history"

comm -23 "$tmp_dir/current-ledger" "$tmp_dir/active-history" > "$tmp_dir/missing-production"
if [[ -s "$tmp_dir/missing-production" ]]; then
  cat "$tmp_dir/missing-production" >&2
  fail "one or more production ledger versions are absent from active migration history"
fi

validated_row_count="$(wc -l < "$tmp_dir/current-ledger" | tr -d ' ')"
[[ "$validated_row_count" == '190' ]] || fail "current production ledger must contain exactly 190 versions; found $validated_row_count"

pending_count="$(comm -13 "$tmp_dir/current-ledger" "$tmp_dir/active-history" | wc -l | tr -d ' ')"

while IFS=, read -r version _name; do
  [[ "$version" == 'version' || "$version" == "$baseline_version" ]] && continue
  mapfile -t matches < <(compgen -G "supabase/migrations/${version}_*.sql" || true)
  [[ "${#matches[@]}" == '1' ]] || fail "production version $version must have exactly one compatibility stub"
  if [[ "$version" < "$baseline_version" ]] && grep -Evq '^[[:space:]]*(--.*)?$' "${matches[0]}"; then
    fail "historical compatibility stub contains executable SQL: ${matches[0]}"
  fi
done < <(printf 'version,name\n'; tail -n +2 "$baseline_ledger"; tail -n +2 "$post_baseline_ledger")

[[ "$(find "$archive" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')" == '48' ]] || fail "expected 48 superseded Core migrations in the audit archive"

echo "Production baseline check passed: $validated_row_count current production versions aligned, schema-only source plus storage supplement verified, 196 tables, 99 functions, 439 policies, safe infrastructure seed, and $pending_count pending migration(s)."
