-- Rollback for 20261113121000_buyer_delivery_address_and_saved_transporter_authority_v1.sql.
-- Buyer builds that call these RPCs must be rolled back first (address/transporter screens would fail closed).
-- ONE transaction: first require prior rollback of Stage-B direct-write hardening;
-- then refuse rollback if the transporter table holds buyer data. NOTHING is dropped before either guard.
-- (no RPCs are removed while data remains). If a client runs this file without ON_ERROR_STOP, the aborted transaction still skips every
-- later statement. The table is locked before the empty check so a concurrent writer cannot commit between the check and the drop.
begin;
do $$
begin
  -- Stage A must not remove the Buyer RPCs until Stage B has restored
  -- the original direct-write privileges AND all four write policies.
  if not (
    has_table_privilege('authenticated','public.delivery_addresses','INSERT')
    and has_table_privilege('authenticated','public.delivery_addresses','UPDATE')
    and has_table_privilege('authenticated','public.delivery_addresses','DELETE')
  ) or (select count(*) from pg_policies
        where schemaname='public' and tablename='delivery_addresses'
          and policyname in (
            'Users can insert their company addresses',
            'Users can insert company addresses',
            'Users can update their company addresses',
            'Users can delete their company addresses'
          )) <> 4 then
    raise exception 'ROLLBACK_ORDER_VIOLATION: first restore 20261113121100 direct-write grants and policies';
  end if;
  if to_regclass('public.customer_saved_transporters') is not null then
    lock table public.customer_saved_transporters in access exclusive mode;
    if exists (select 1 from public.customer_saved_transporters) then
      raise exception 'ROLLBACK_REFUSED: public.customer_saved_transporters holds buyer data; export it before dropping the table';
    end if;
  end if;
end $$;
drop function if exists public.customer_upsert_delivery_address_v1(uuid, text, text, text, text, text, text, text, boolean);
drop function if exists public.customer_delete_delivery_address_v1(uuid);
drop function if exists public.customer_saved_transporters_v1();
drop function if exists public.customer_upsert_saved_transporter_v1(uuid, text, text, boolean, boolean);
drop function if exists public.customer_delete_saved_transporter_v1(uuid);
drop table if exists public.customer_saved_transporters;
-- The feature overrides the existing Buyer address read projection; rollback
-- must restore the pre-feature projection and its permissions atomically.
CREATE OR REPLACE FUNCTION public.customer_delivery_addresses_v1()
RETURNS TABLE (
  address_id uuid,
  label text,
  street_address text,
  city text,
  state text,
  pincode text,
  contact_person text,
  contact_phone text,
  is_default boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    da.id AS address_id,
    da.label,
    da.street_address,
    da.city,
    da.state,
    da.pincode,
    nullif(btrim(da.contact_person), '') AS contact_person,
    nullif(btrim(da.contact_phone), '') AS contact_phone,
    coalesce(da.is_default, false) AS is_default,
    da.created_at
  FROM eligible e
  JOIN public.delivery_addresses da
    ON da.company_id = e.company_id
       OR (da.company_id IS NULL AND da.user_id = auth.uid())
  WHERE e.company_id IS NOT NULL
  ORDER BY coalesce(da.is_default, false) DESC, da.created_at DESC, da.id;
$$;

COMMENT ON FUNCTION public.customer_delivery_addresses_v1() IS
  'Buyer-safe saved delivery addresses for the canonical authenticated approved Buyer company, plus caller-owned legacy rows with no company_id. No client-supplied tenant identifier.';

REVOKE ALL ON FUNCTION public.customer_delivery_addresses_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_delivery_addresses_v1() TO authenticated, service_role;


commit;
