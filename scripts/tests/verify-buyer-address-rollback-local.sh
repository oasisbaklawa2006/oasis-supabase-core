#!/usr/bin/env bash
# Reverse-order Buyer address rollback test on the disposable local Supabase DB ONLY.
# Intentionally alters/drops functions and policies as the very LAST local CI test.
set -euo pipefail
: "$DB_URL"
case "$DB_URL" in
  postgresql://*@127.0.0.1:*|postgres://*@127.0.0.1:*|postgresql://*@localhost:*|postgres://*@localhost:*) ;;
  *) echo "BUYER_ADDRESS_ROLLBACK_TEST: refusing non-local DB_URL" >&2; exit 1 ;;
esac
command -v psql >/dev/null || exit 1
stage_a="supabase/rollback/20261109104000_buyer_delivery_address_and_saved_transporter_authority_v1_down.sql"
stage_b="supabase/rollback/20261109104100_delivery_addresses_direct_write_hardening_v1_down.sql"
[[ -f "$stage_a" && -f "$stage_b" ]] || { echo 'Missing rollback scripts' >&2; exit 1; }
sql() {
  PGCONNECT_TIMEOUT=10 PGOPTIONS='-c lock_timeout=5s -c statement_timeout=90s' \
    psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=1 "$@"
}
assert_true() {
  local observed
  observed="$(sql -c "$1")"
  [[ "$observed" == t ]] || { echo "BUYER_ADDRESS_ROLLBACK_TEST: FAIL $2; got $observed" >&2; exit 1; }
}
# Disposable synthetic company and transporter, no production or customer records.
company_id="$(sql -c "INSERT INTO public.companies(business_name,status) VALUES ('Buyer Rollback Probe','active') RETURNING id;")"
[[ "$company_id" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Invalid synthetic company ID' >&2; exit 1; }
sql -c "INSERT INTO public.customer_saved_transporters(company_id,transporter_name) VALUES ('$company_id','ROLLBACK-GUARD-TRANSPORTER');" >/dev/null
guard_log="$(mktemp)"
trap 'rm -f "$guard_log"' EXIT
if sql -f "$stage_a" >"$guard_log" 2>&1; then
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: FAIL nonempty rollback erroneously succeeded' >&2
  exit 1
fi
grep -q 'ROLLBACK_REFUSED: public.customer_saved_transporters holds buyer data' "$guard_log" || {
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: unexpected rollback error' >&2; exit 1;
}
assert_true "SELECT to_regprocedure('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)') IS NOT NULL AND to_regprocedure('public.customer_saved_transporters_v1()') IS NOT NULL AND EXISTS(SELECT 1 FROM public.customer_saved_transporters WHERE company_id='$company_id');" "nonempty-data guard preserves functions and rows"
# Only the synthetic transporter row must be cleared to prove the empty-data rollback.
# The synthetic company can remain until the disposable local Supabase stack is
# destroyed; company creation triggers wallet-opening evidence with a
# non-cascading foreign key, so deleting the company here would fail.
sql -c "DELETE FROM public.customer_saved_transporters WHERE company_id='$company_id';" >/dev/null
assert_true "SELECT count(*)=0 FROM public.customer_saved_transporters;" "test requires empty transporter table"
# Both rollback scripts have their own BEGIN/COMMIT. Test in reverse
# chronological order after all other CI checks, on disposable local stack.
sql -f "$stage_b" >/dev/null
assert_true "SELECT has_table_privilege('authenticated','public.delivery_addresses','INSERT') AND has_table_privilege('authenticated','public.delivery_addresses','UPDATE') AND has_table_privilege('anon','public.delivery_addresses','TRUNCATE') AND (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='delivery_addresses' AND policyname IN ('Users can insert their company addresses','Users can insert company addresses','Users can update their company addresses','Users can delete their company addresses'))=4;" "stage-B restores four write policies and original grants"
sql -f "$stage_a" >/dev/null
assert_true "SELECT to_regclass('public.customer_saved_transporters') IS NULL AND to_regprocedure('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)') IS NULL AND to_regprocedure('public.customer_delete_delivery_address_v1(uuid)') IS NULL AND to_regprocedure('public.customer_saved_transporters_v1()') IS NULL AND to_regprocedure('public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)') IS NULL AND to_regprocedure('public.customer_delete_saved_transporter_v1(uuid)') IS NULL AND to_regprocedure('public.customer_delivery_addresses_v1()') IS NOT NULL;" "stage-A restores original read projection and drops new RPCs/table"
assert_true "SELECT pg_get_functiondef('public.customer_delivery_addresses_v1()'::regprocedure) ILIKE '%ORDER BY COALESCE(da.is_default, false) DESC%' AND has_table_privilege('authenticated','public.delivery_addresses','INSERT');" "stage-A read ordering and grants restored"
echo "BUYER_ADDRESS_ROLLBACK_TEST: PASS data guard and reverse-order executed rollback"
