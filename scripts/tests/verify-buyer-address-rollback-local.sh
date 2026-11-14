#!/usr/bin/env bash
# Reverse-order Buyer address rollback test on the disposable local Supabase DB ONLY.
# Intentionally alters/drops functions and policies as the very LAST local CI test.
set -euo pipefail
: "$DB_URL"
# Accept only an explicit loopback PostgreSQL URI with no query string,
# fragment, alternate host/address or socket/routing parameter. In particular,
# a URI ?hostaddr=... must NEVER redirect destructive rollback SQL off-host.
if [[ ! "$DB_URL" =~ ^postgres(ql)?://[^/?#@]+@(127[.]0[.]0[.]1|localhost):[0-9]{1,5}/[A-Za-z0-9_]+$ ]]; then
  echo "BUYER_ADDRESS_ROLLBACK_TEST: refusing non-local or routed DB_URL" >&2
  exit 1
fi
# libpq environment defaults can supply a different hostaddr or service even
# when the URI appears local. Clear them before the first SQL connection.
unset PGHOSTADDR PGHOST PGPORT PGDATABASE PGUSER PGSERVICE PGSERVICEFILE \
  PGSYSCONFDIR PGOPTIONS PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY \
  PGCHANNELBINDING PGREQUIREAUTH PGAPPNAME
command -v psql >/dev/null || exit 1
stage_a="supabase/rollback/20261113121000_buyer_delivery_address_and_saved_transporter_authority_v1_down.sql"
stage_b="supabase/rollback/20261113121100_delivery_addresses_direct_write_hardening_v1_down.sql"
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
# A wrong-order rollback must fail BEFORE removing governed Buyer RPCs,
# including if the transporter table is nonempty.
if sql -f "$stage_a" >"$guard_log" 2>&1; then
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: FAIL stage-A rolled back before stage-B' >&2; exit 1
fi
grep -q 'ROLLBACK_ORDER_VIOLATION:' "$guard_log" || {
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: unexpected order-guard error' >&2; exit 1;
}
assert_true "SELECT to_regprocedure('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)') IS NOT NULL AND EXISTS(SELECT 1 FROM public.customer_saved_transporters WHERE company_id='$company_id');" "wrong-order rollback preserves functions and transporter"
# Correct the chronology first. Stage B restores direct-write grants and
# policies, then Stage A must still refuse to discard saved transporter data.
sql -f "$stage_b" >/dev/null
assert_true "SELECT has_table_privilege('authenticated','public.delivery_addresses','INSERT') AND has_table_privilege('authenticated','public.delivery_addresses','UPDATE') AND has_table_privilege('anon','public.delivery_addresses','TRUNCATE') AND (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='delivery_addresses' AND policyname IN ('Users can insert their company addresses','Users can insert company addresses','Users can update their company addresses','Users can delete their company addresses'))=4;" "stage-B restores write policies and grants"
if sql -f "$stage_a" >"$guard_log" 2>&1; then
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: FAIL stage-A dropped functions with transporter data' >&2; exit 1
fi
grep -q 'ROLLBACK_REFUSED: public.customer_saved_transporters holds buyer data' "$guard_log" || {
  echo 'BUYER_ADDRESS_ROLLBACK_TEST: unexpected data guard error' >&2; exit 1;
}
assert_true "SELECT to_regprocedure('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)') IS NOT NULL AND to_regprocedure('public.customer_saved_transporters_v1()') IS NOT NULL AND EXISTS(SELECT 1 FROM public.customer_saved_transporters WHERE company_id='$company_id');" "nonempty-data rollback preserves RPCs and rows"
# The generated company can remain until the disposable CI database is
# destroyed: it owns automatic wallet evidence with an FK. Only the synthetic
# transporter must be deleted to enable the empty-table rollback test.
sql -c "DELETE FROM public.customer_saved_transporters WHERE company_id='$company_id';" >/dev/null
assert_true "SELECT count(*)=0 FROM public.customer_saved_transporters;" "test requires empty transporter table"
# Execute the ACTUAL Stage-A rollback last, now in correct reverse order.
sql -f "$stage_a" >/dev/null
assert_true "SELECT to_regclass('public.customer_saved_transporters') IS NULL AND to_regprocedure('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)') IS NULL AND to_regprocedure('public.customer_delete_delivery_address_v1(uuid)') IS NULL AND to_regprocedure('public.customer_saved_transporters_v1()') IS NULL AND to_regprocedure('public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)') IS NULL AND to_regprocedure('public.customer_delete_saved_transporter_v1(uuid)') IS NULL AND to_regprocedure('public.customer_delivery_addresses_v1()') IS NOT NULL;" "stage-A restores original read projection and drops new RPCs/table"
assert_true "SELECT pg_get_functiondef('public.customer_delivery_addresses_v1()'::regprocedure) ILIKE '%ORDER BY COALESCE(da.is_default, false) DESC%' AND has_table_privilege('authenticated','public.delivery_addresses','INSERT');" "stage-A read ordering and grants restored"
echo "BUYER_ADDRESS_ROLLBACK_TEST: PASS data guard and reverse-order executed rollback"
