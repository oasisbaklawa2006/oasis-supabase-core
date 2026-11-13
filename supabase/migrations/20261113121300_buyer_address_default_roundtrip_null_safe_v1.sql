-- Forward-only round-trip and NULL input correction following 20261113121200.
-- Restore agreement between saved responses and viewer-effective list defaults.
-- Preserve every previously applied Preview migration immutable. No data changes.
-- The default is projected via the same buyer-scoped read RPC used by the app.

-- Forward-only correction to the Buyer address saved-default write authority.
-- The original 20261113121000 migration was already applied in hosted Preview.
-- Preserve its history and replace the function in a new immutable version.
-- No table data or existing address defaults are changed by this migration.

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
      UPDATE public.delivery_addresses AS da
      SET is_default=false
      WHERE da.company_id IS NULL AND da.user_id=v_actor AND da.is_default IS TRUE;
    ELSE
      UPDATE public.delivery_addresses AS da
      SET is_default=false
      WHERE da.company_id=v_company AND da.is_default IS TRUE;
      -- An explicit shared-default choice supersedes only this caller's
      -- private override, never a different buyer's legacy private default.
      UPDATE public.delivery_addresses AS da
      SET is_default=false
      WHERE da.company_id IS NULL AND da.user_id=v_actor AND da.is_default IS TRUE;
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
    -- The read projection reports a viewer-EFFECTIVE default, which is false
    -- for the company default when this caller has a private legacy override.
    -- An unchanged edit from that UI must not silently demote the shared
    -- company default for every other Buyer in this company.
    is_default=CASE
      WHEN public.delivery_addresses.company_id=v_company
       AND public.delivery_addresses.is_default IS TRUE
       AND coalesce(p_is_default,false) IS FALSE
       AND EXISTS (
         SELECT 1 FROM public.delivery_addresses AS personal
         WHERE personal.company_id IS NULL
           AND personal.user_id=v_actor AND personal.is_default IS TRUE
       )
      THEN TRUE
      ELSE excluded.is_default
    END
  WHERE public.delivery_addresses.company_id=v_company
     OR (public.delivery_addresses.company_id IS NULL AND public.delivery_addresses.user_id=v_actor)
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;

  RETURN QUERY SELECT
    v_row.id,v_row.label,v_row.street_address,v_row.city,v_row.state,v_row.pincode,
    nullif(btrim(v_row.contact_person),''),nullif(btrim(v_row.contact_phone),''),
    coalesce((SELECT projected.is_default
              FROM public.customer_delivery_addresses_v1() AS projected
              WHERE projected.address_id=v_row.id LIMIT 1),false),v_row.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean) TO authenticated,service_role;
