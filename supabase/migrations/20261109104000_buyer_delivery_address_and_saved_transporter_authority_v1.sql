-- Buyer saved delivery-address write authority + saved-transporter master (compatibility restore).
--
-- WHY: the Buyer app (AddressesScreen, TransporterScreen via src/lib/api/account-preferences.ts) calls five RPCs that exist
-- in neither Core main nor production (read-only check 2026-11-02):
--   customer_upsert_delivery_address_v1, customer_delete_delivery_address_v1,
--   customer_saved_transporters_v1, customer_upsert_saved_transporter_v1, customer_delete_saved_transporter_v1.
-- They were only defined in the closed (never merged) PR #399 migration 20261029030000, sections F and G.
-- This migration restores ONLY those two sections, unchanged in behaviour. The other #399 sections (product-history
-- delete guard, department/application/rescue-payment authority, payment-provider runtime) are deliberately NOT included.
-- Reviewed against production: public.delivery_addresses and companies.preferred_courier/courier_account_number already
-- exist with the columns used here; customer_delivery_addresses_v1 (read) already exists in Core main.
--
-- Hardening added vs #399: created_by is nullable with ON DELETE SET NULL (account deletion is not blocked by saved transporters), and a partial unique index guarantees at most one default transporter per company
-- (the advisory lock already serialised writers; the index makes the invariant structural).
--
-- Additive. No existing function is changed. Direct table grants on public.delivery_addresses are NOT altered here.

-- A. Buyer saved delivery-address write authority.
CREATE OR REPLACE FUNCTION public.customer_upsert_delivery_address_v1(
  p_address_id uuid,
  p_label text,
  p_street_address text,
  p_city text,
  p_state text,
  p_pincode text,
  p_contact_person text DEFAULT NULL,
  p_contact_phone text DEFAULT NULL,
  p_is_default boolean DEFAULT false
)
RETURNS TABLE(
  address_id uuid,label text,street_address text,city text,state text,pincode text,
  contact_person text,contact_phone text,is_default boolean,created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.delivery_addresses%rowtype;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_address_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ID_REQUIRED' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(coalesce(p_label,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_street_address,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_city,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_state,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_pincode,'')),'') IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_REQUIRED_FIELDS' USING ERRCODE='22023';
  END IF;
  IF length(btrim(p_label))>80 OR length(btrim(p_street_address))>500
     OR length(btrim(p_city))>120 OR length(btrim(p_state))>120
     OR length(btrim(p_pincode))>20
     OR length(coalesce(btrim(p_contact_person),''))>120
     OR length(coalesce(btrim(p_contact_phone),''))>30 THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_FIELD_TOO_LONG' USING ERRCODE='22001';
  END IF;
  IF concat_ws('',p_label,p_street_address,p_city,p_state,p_pincode,p_contact_person,p_contact_phone) ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_CONTROL_CHAR_FORBIDDEN' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-address:'||v_company::text,0));

  IF coalesce(p_is_default,false) THEN
    -- A caller-private legacy address is not a company-shared preference.
    -- Do not erase the company default when the caller picks a private default.
    IF EXISTS (
      SELECT 1 FROM public.delivery_addresses
      WHERE id=p_address_id AND company_id IS NULL AND user_id=v_actor
    ) THEN
      UPDATE public.delivery_addresses
      SET is_default=false
      WHERE company_id IS NULL AND user_id=v_actor AND is_default IS TRUE;
    ELSE
      UPDATE public.delivery_addresses
      SET is_default=false
      WHERE company_id=v_company AND is_default IS TRUE;
    END IF;
  END IF;

  INSERT INTO public.delivery_addresses(
    id,company_id,user_id,label,street_address,city,state,pincode,contact_person,contact_phone,is_default
  ) VALUES (
    p_address_id,v_company,v_actor,btrim(p_label),btrim(p_street_address),btrim(p_city),btrim(p_state),btrim(p_pincode),
    nullif(btrim(p_contact_person),''),nullif(btrim(p_contact_phone),''),coalesce(p_is_default,false)
  )
  ON CONFLICT (id) DO UPDATE SET
    -- Legacy owner-private rows are visible only to their owning Buyer.
    -- Editing one must not silently publish it as company-shared data.
    company_id=CASE WHEN public.delivery_addresses.company_id IS NULL
                    THEN NULL ELSE excluded.company_id END,
    user_id=CASE WHEN public.delivery_addresses.company_id IS NULL
                THEN public.delivery_addresses.user_id ELSE excluded.user_id END,
    label=excluded.label,
    street_address=excluded.street_address,
    city=excluded.city,
    state=excluded.state,
    pincode=excluded.pincode,
    contact_person=excluded.contact_person,
    contact_phone=excluded.contact_phone,
    is_default=excluded.is_default
  WHERE public.delivery_addresses.company_id=v_company
     OR (public.delivery_addresses.company_id IS NULL AND public.delivery_addresses.user_id=v_actor)
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;

  RETURN QUERY SELECT
    v_row.id,v_row.label,v_row.street_address,v_row.city,v_row.state,v_row.pincode,
    nullif(btrim(v_row.contact_person),''),nullif(btrim(v_row.contact_phone),''),
    coalesce(v_row.is_default,false),v_row.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_delivery_address_v1(p_address_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_was_default boolean;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-address:'||v_company::text,0));

  SELECT coalesce(is_default,false) INTO v_was_default
  FROM public.delivery_addresses
  WHERE id=p_address_id
    AND (company_id=v_company OR (company_id IS NULL AND user_id=v_actor))
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  DELETE FROM public.delivery_addresses
  WHERE id=p_address_id
    AND (company_id=v_company OR (company_id IS NULL AND user_id=v_actor));

  IF coalesce(v_was_default,false)
     AND NOT EXISTS (
       SELECT 1 FROM public.delivery_addresses
       WHERE company_id=v_company AND coalesce(is_default,false)
     ) THEN
    UPDATE public.delivery_addresses da
    SET is_default=true
    WHERE da.id=(
      SELECT id FROM public.delivery_addresses
      WHERE company_id=v_company
      ORDER BY created_at DESC,id
      LIMIT 1
    );
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)
  FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_delete_delivery_address_v1(uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)
  TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_delete_delivery_address_v1(uuid)
  TO authenticated,service_role;

-- B. Multi-saved transporter master + Buyer authority.
CREATE TABLE IF NOT EXISTS public.customer_saved_transporters(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  transporter_name text NOT NULL,
  account_number text,
  is_default boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL, -- audit hint only; the row belongs to the company, so deleting the creating user must not block or delete it
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT customer_saved_transporters_name_nonempty CHECK (nullif(btrim(transporter_name),'') IS NOT NULL),
  CONSTRAINT customer_saved_transporters_name_len CHECK (length(transporter_name)<=120),
  CONSTRAINT customer_saved_transporters_account_len CHECK (account_number IS NULL OR length(account_number)<=120),
  CONSTRAINT customer_saved_transporters_default_active CHECK (NOT is_default OR is_active)
);

ALTER TABLE public.customer_saved_transporters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_saved_transporters FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.customer_saved_transporters TO service_role;

CREATE INDEX IF NOT EXISTS customer_saved_transporters_company_idx
  ON public.customer_saved_transporters(company_id,is_active DESC,is_default DESC,updated_at DESC);

CREATE OR REPLACE FUNCTION public.customer_saved_transporters_v1()
RETURNS TABLE(
  transporter_id uuid,transporter_name text,account_number text,is_default boolean,is_active boolean,
  created_at timestamptz,updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    t.id,t.transporter_name,nullif(btrim(t.account_number),''),
    t.is_default,t.is_active,t.created_at,t.updated_at
  FROM eligible e
  JOIN public.customer_saved_transporters t ON t.company_id=e.company_id
  WHERE e.company_id IS NOT NULL
  ORDER BY t.is_default DESC,t.is_active DESC,t.updated_at DESC,t.id;
$$;

CREATE OR REPLACE FUNCTION public.customer_upsert_saved_transporter_v1(
  p_transporter_id uuid,
  p_transporter_name text,
  p_account_number text DEFAULT NULL,
  p_is_default boolean DEFAULT false,
  p_is_active boolean DEFAULT true
)
RETURNS TABLE(
  transporter_id uuid,transporter_name text,account_number text,is_default boolean,is_active boolean,
  created_at timestamptz,updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.customer_saved_transporters%rowtype;
  v_was_default boolean := false;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_transporter_id IS NULL OR nullif(btrim(coalesce(p_transporter_name,'')),'') IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_REQUIRED_FIELDS' USING ERRCODE='22023';
  END IF;
  IF length(btrim(p_transporter_name))>120
     OR length(coalesce(btrim(p_account_number),''))>120 THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_FIELD_TOO_LONG' USING ERRCODE='22001';
  END IF;
  IF concat_ws('',p_transporter_name,p_account_number) ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_CONTROL_CHAR_FORBIDDEN' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-transporter:'||v_company::text,0));

  -- Remember whether this row was the default before the upsert: the legacy
  -- companies.preferred_courier mirror must follow default changes only.
  SELECT coalesce(t.is_default AND t.is_active,false) INTO v_was_default
  FROM public.customer_saved_transporters AS t
  WHERE t.id=p_transporter_id AND t.company_id=v_company;
  v_was_default := coalesce(v_was_default,false);

  IF coalesce(p_is_default,false) AND coalesce(p_is_active,true) THEN
    UPDATE public.customer_saved_transporters AS t
    SET is_default=false,updated_at=statement_timestamp()
    WHERE t.company_id=v_company AND t.is_default;
  END IF;

  INSERT INTO public.customer_saved_transporters(
    id,company_id,transporter_name,account_number,is_default,is_active,created_by
  ) VALUES (
    p_transporter_id,v_company,btrim(p_transporter_name),nullif(btrim(p_account_number),''),
    (coalesce(p_is_default,false) AND coalesce(p_is_active,true)),coalesce(p_is_active,true),v_actor
  )
  ON CONFLICT (id) DO UPDATE SET
    transporter_name=excluded.transporter_name,
    account_number=excluded.account_number,
    is_default=excluded.is_default,
    is_active=excluded.is_active,
    updated_at=statement_timestamp()
  WHERE public.customer_saved_transporters.company_id=v_company
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;

  -- Sync the legacy mirror only when the default changed (this row became the default, or it was
  -- the default and no longer is). Saving a non-default transporter must not erase a legacy
  -- preferred_courier that was never managed through saved transporters.
  IF (v_row.is_default AND v_row.is_active) OR v_was_default THEN
    UPDATE public.companies AS c
    SET (preferred_courier,courier_account_number)=(
      SELECT t.transporter_name,t.account_number
      FROM public.customer_saved_transporters AS t
      WHERE t.company_id=v_company
        AND t.is_default
        AND t.is_active
      ORDER BY t.updated_at DESC,t.id
      LIMIT 1
    )
    WHERE c.id=v_company;
  END IF;

  RETURN QUERY SELECT
    v_row.id,v_row.transporter_name,nullif(btrim(v_row.account_number),''),
    v_row.is_default,v_row.is_active,v_row.created_at,v_row.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_saved_transporter_v1(p_transporter_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.customer_saved_transporters%rowtype;
  v_replacement public.customer_saved_transporters%rowtype;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-transporter:'||v_company::text,0));

  SELECT * INTO v_row
  FROM public.customer_saved_transporters
  WHERE id=p_transporter_id AND company_id=v_company
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  DELETE FROM public.customer_saved_transporters
  WHERE id=p_transporter_id AND company_id=v_company;

  IF v_row.is_default THEN
    SELECT t.* INTO v_replacement
    FROM public.customer_saved_transporters AS t
    WHERE t.company_id=v_company AND t.is_active
    ORDER BY t.updated_at DESC,t.id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.customer_saved_transporters AS t
      SET is_default=(t.id=v_replacement.id),
          updated_at=CASE WHEN t.id=v_replacement.id THEN statement_timestamp() ELSE t.updated_at END
      WHERE t.company_id=v_company;

      UPDATE public.companies
      SET preferred_courier=v_replacement.transporter_name,
          courier_account_number=v_replacement.account_number
      WHERE id=v_company;
    ELSE
      UPDATE public.companies
      SET preferred_courier=NULL,courier_account_number=NULL
      WHERE id=v_company;
    END IF;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_saved_transporters_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_delete_saved_transporter_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_saved_transporters_v1() TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)
  TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_delete_saved_transporter_v1(uuid)
  TO authenticated,service_role;

-- At most one default saved transporter per company (structural guarantee behind the advisory lock).
CREATE UNIQUE INDEX IF NOT EXISTS customer_saved_transporters_one_default_per_company
  ON public.customer_saved_transporters(company_id) WHERE is_default;

-- Preserve the existing customer_delivery_addresses_v1 result signature while
-- exposing exactly one effective default per viewer. A caller-private legacy
-- default takes precedence for that caller, while the company default remains
-- visible to other eligible buyers. No private address is published.
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  ), visible AS (
    SELECT da.*, CASE WHEN da.company_id IS NULL THEN 0 ELSE 1 END AS scope_priority
    FROM eligible e
    JOIN public.delivery_addresses da
      ON da.company_id=e.company_id
      OR (da.company_id IS NULL AND da.user_id=auth.uid())
    WHERE e.company_id IS NOT NULL
  ), ranked AS (
    SELECT v.*,
      row_number() OVER (
        PARTITION BY coalesce(v.is_default,false)
        ORDER BY v.scope_priority ASC, v.created_at DESC, v.id
      ) AS default_rank
    FROM visible v
  )
  SELECT
    v.id AS address_id,v.label,v.street_address,v.city,v.state,v.pincode,
    nullif(btrim(v.contact_person),''),nullif(btrim(v.contact_phone),''),
    (coalesce(v.is_default,false) AND v.default_rank=1) AS is_default,
    v.created_at
  FROM ranked v
  ORDER BY (coalesce(v.is_default,false) AND v.default_rank=1) DESC,
    v.created_at DESC,v.id;
$$;
REVOKE ALL ON FUNCTION public.customer_delivery_addresses_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_delivery_addresses_v1() TO authenticated,service_role;
