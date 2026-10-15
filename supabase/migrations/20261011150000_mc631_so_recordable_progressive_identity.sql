-- MC#631 — SO_RECORDABLE vs downstream readiness gates + progressive customer identity clues.
-- Reuses canonical WhatsApp resolver, CORE-A/B promotion, and WA-3 evidence; no parallel order system.
begin;

-- ---------------------------------------------------------------------------
-- SO_RECORDABLE readiness (client + product + quantity). Billing/shipping/transporter
-- remain downstream gates (BILLING_READY / DISPATCH_READY unchanged).
-- ---------------------------------------------------------------------------
create or replace function public.validate_sales_order_so_recordable_readiness(p_dimensions jsonb)
returns void
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  v_key text;
  v_dim jsonb;
  v_required text[] := array['client', 'product', 'quantity'];
  v_min_score constant integer := 40;
begin
  foreach v_key in array v_required
  loop
    select elem
    into v_dim
    from jsonb_array_elements(coalesce(p_dimensions, '[]'::jsonb)) as elem
    where elem->>'dimension' = v_key
    limit 1;

    if v_dim is null then
      raise exception 'Missing readiness dimension: %', v_key;
    end if;

    if coalesce(v_dim->>'status', 'missing') = 'missing'
      or coalesce((v_dim->>'score')::integer, 0) < v_min_score then
      raise exception '% is not ready (% — %)', v_key, v_dim->>'score', v_dim->>'status';
    end if;
  end loop;
end;
$$;

revoke all on function public.validate_sales_order_so_recordable_readiness(jsonb) from public, anon, authenticated;
grant execute on function public.validate_sales_order_so_recordable_readiness(jsonb) to service_role;

comment on function public.validate_sales_order_so_recordable_readiness(jsonb) is
  'MC#631: minimum governed dimensions to record a Sales Order without billing address, GST invoice facts, or dispatch destination.';

create or replace function public.evaluate_whatsapp_order_so_recordable_readiness(p_potential_order_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  with required(field_key) as (
    values
      ('client_identity'),
      ('product'),
      ('quantity'),
      ('unit_packaging'),
      ('moq_carton')
  ),
  dimensions as (
    select
      r.field_key,
      coalesce(f.resolution_state, 'unresolved') as state,
      coalesce(f.is_required, true) as is_required
    from required r
    left join public.whatsapp_order_field_resolutions f
      on f.potential_order_id = p_potential_order_id
     and f.field_key = r.field_key
  )
  select jsonb_build_object(
    'gate', 'SO_RECORDABLE',
    'ready', bool_and(
      (not is_required and state = 'not_applicable')
      or state in ('resolved', 'operator_confirmed')
    ),
    'dimensions', jsonb_agg(
      jsonb_build_object('field_key', field_key, 'state', state, 'required', is_required)
      order by field_key
    ),
    'blocking_fields', coalesce(
      jsonb_agg(field_key order by field_key) filter (
        where not (
          (not is_required and state = 'not_applicable')
          or state in ('resolved', 'operator_confirmed')
        )
      ),
      '[]'::jsonb
    )
  )
  from dimensions;
$$;

revoke all on function public.evaluate_whatsapp_order_so_recordable_readiness(uuid) from public, anon;
grant execute on function public.evaluate_whatsapp_order_so_recordable_readiness(uuid) to authenticated, service_role;

comment on function public.evaluate_whatsapp_order_so_recordable_readiness(uuid) is
  'WA-3 subset for early SO capture: commercial identity + product + quantity (+ packaging/MOQ when applicable).';

create or replace function public.whatsapp_core_b_governed_facts_so_recordable(p_governed_facts jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(p_governed_facts->'customer'->>'company_id', '') <> ''
    and jsonb_typeof(p_governed_facts->'order_lines') = 'array'
    and jsonb_array_length(p_governed_facts->'order_lines') > 0;
$$;

revoke all on function public.whatsapp_core_b_governed_facts_so_recordable(jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_core_b_governed_facts_so_recordable(jsonb) to service_role;

create or replace function public.whatsapp_core_b_governed_facts_draft_eligible(p_governed_facts jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select public.whatsapp_core_b_governed_facts_so_recordable(p_governed_facts);
$$;

create or replace function public.whatsapp_build_core_b_readiness_dimensions(p_governed_facts jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when public.whatsapp_core_b_governed_facts_so_recordable(p_governed_facts) then
      jsonb_build_array(
        jsonb_build_object('dimension', 'client', 'status', 'ready', 'score', 100, 'gate', 'SO_RECORDABLE'),
        jsonb_build_object('dimension', 'product', 'status', 'ready', 'score', 100, 'gate', 'SO_RECORDABLE'),
        jsonb_build_object('dimension', 'quantity', 'status', 'ready', 'score', 100, 'gate', 'SO_RECORDABLE'),
        jsonb_build_object(
          'dimension', 'address',
          'status', case when coalesce(p_governed_facts->'branch'->>'delivery_address_id', '') <> '' then 'ready' else 'pending' end,
          'score', case when coalesce(p_governed_facts->'branch'->>'delivery_address_id', '') <> '' then 100 else 0 end,
          'gate', 'DISPATCH_READY',
          'hold_code', case when coalesce(p_governed_facts->'branch'->>'delivery_address_id', '') = '' then 'DELIVERY_DETAILS_PENDING' else null end
        ),
        jsonb_build_object(
          'dimension', 'payment_terms',
          'status', case when coalesce(p_governed_facts->'customer'->>'payment_terms', '') <> '' then 'ready' else 'pending' end,
          'score', case when coalesce(p_governed_facts->'customer'->>'payment_terms', '') <> '' then 100 else 0 end,
          'gate', 'BILLING_READY',
          'hold_code', case when coalesce(p_governed_facts->'customer'->>'payment_terms', '') = '' then 'BILLING_DETAILS_PENDING' else null end
        )
      )
    else jsonb_build_array(
      jsonb_build_object(
        'dimension', 'client',
        'status', case when coalesce(p_governed_facts->'customer'->>'company_id', '') <> '' then 'ready' else 'blocked' end,
        'score', case when coalesce(p_governed_facts->'customer'->>'company_id', '') <> '' then 100 else 0 end,
        'gate', 'SO_RECORDABLE'
      ),
      jsonb_build_object(
        'dimension', 'product',
        'status', case
          when jsonb_typeof(p_governed_facts->'order_lines') = 'array'
            and jsonb_array_length(p_governed_facts->'order_lines') > 0 then 'ready'
          else 'blocked'
        end,
        'score', case
          when jsonb_typeof(p_governed_facts->'order_lines') = 'array'
            and jsonb_array_length(p_governed_facts->'order_lines') > 0 then 100
          else 0
        end,
        'gate', 'SO_RECORDABLE'
      ),
      jsonb_build_object(
        'dimension', 'quantity',
        'status', case
          when jsonb_typeof(p_governed_facts->'order_lines') = 'array'
            and jsonb_array_length(p_governed_facts->'order_lines') > 0 then 'ready'
          else 'blocked'
        end,
        'score', case
          when jsonb_typeof(p_governed_facts->'order_lines') = 'array'
            and jsonb_array_length(p_governed_facts->'order_lines') > 0 then 100
          else 0
        end,
        'gate', 'SO_RECORDABLE'
      ),
      jsonb_build_object('dimension', 'address', 'status', 'blocked', 'score', 0, 'gate', 'DISPATCH_READY'),
      jsonb_build_object('dimension', 'payment_terms', 'status', 'blocked', 'score', 0, 'gate', 'BILLING_READY')
    )
  end;
$$;

-- ---------------------------------------------------------------------------
-- Progressive identity helpers (message-body phone + name/location/person narrowing).
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_normalize_identity_phone(p_raw text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select lower(regexp_replace(coalesce(p_raw, ''), '\D', '', 'g'));
$$;

revoke all on function public.whatsapp_normalize_identity_phone(text) from public, anon, authenticated;
grant execute on function public.whatsapp_normalize_identity_phone(text) to authenticated, service_role;

create or replace function public.whatsapp_match_companies_by_normalized_phone(p_phone text)
returns uuid[]
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with active_companies as (
    select c.id
    from public.companies c
    where lower(coalesce(c.status, '')) in ('active', 'approved')
  )
  select coalesce(array_agg(distinct x.company_id), '{}'::uuid[])
  from (
    select c.id as company_id
    from public.companies c
    join active_companies ac on ac.id = c.id
    where c.phone = p_phone
       or lower(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g')) = p_phone
    union
    select da.company_id
    from public.delivery_addresses da
    join active_companies ac on ac.id = da.company_id
    where da.contact_phone = p_phone
       or lower(regexp_replace(coalesce(da.contact_phone, ''), '\D', '', 'g')) = p_phone
    union
    select c.id
    from public.b2b_applications ba
    join public.companies c on upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
      = upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
    join active_companies ac on ac.id = c.id
    where ba.status = 'approved'
      and (
        ba.contact_phone = p_phone
        or ba.mobile_number = p_phone
        or lower(regexp_replace(coalesce(ba.contact_phone, ''), '\D', '', 'g')) = p_phone
        or lower(regexp_replace(coalesce(ba.mobile_number, ''), '\D', '', 'g')) = p_phone
      )
  ) x;
$$;

revoke all on function public.whatsapp_match_companies_by_normalized_phone(text) from public, anon, authenticated;
grant execute on function public.whatsapp_match_companies_by_normalized_phone(text) to service_role;

create or replace function public.whatsapp_narrow_company_ids_by_identity_clues(
  p_company_ids uuid[],
  p_candidate jsonb
)
returns uuid[]
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_location text;
  v_person text;
  v_ids uuid[] := coalesce(p_company_ids, '{}'::uuid[]);
  v_filtered uuid[];
begin
  if cardinality(v_ids) <= 1 then
    return v_ids;
  end if;

  v_location := lower(btrim(coalesce(
    nullif(p_candidate->>'location', ''),
    nullif(p_candidate->>'area', ''),
    nullif(p_candidate->>'branch', ''),
    nullif(p_candidate->>'city', ''),
    ''
  )));

  if v_location <> '' then
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_filtered
    from public.companies c
    where c.id = any(v_ids)
      and (
        lower(coalesce(c.business_name, '')) like '%' || v_location || '%'
        or exists (
          select 1
          from public.delivery_addresses da
          where da.company_id = c.id
            and (
              lower(coalesce(da.city, '')) like '%' || v_location || '%'
              or lower(coalesce(da.label, '')) like '%' || v_location || '%'
              or lower(coalesce(da.street_address, '')) like '%' || v_location || '%'
            )
        )
      );

    if cardinality(v_filtered) >= 1 then
      v_ids := v_filtered;
    end if;
  end if;

  if cardinality(v_ids) <= 1 then
    return v_ids;
  end if;

  v_person := lower(btrim(coalesce(
    nullif(p_candidate->>'concerned_person', ''),
    nullif(p_candidate->>'contact_person', ''),
    nullif(p_candidate->>'person_name', ''),
    ''
  )));

  if v_person <> '' then
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_filtered
    from public.companies c
    where c.id = any(v_ids)
      and (
        exists (
          select 1
          from public.b2b_applications ba
          where ba.status = 'approved'
            and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
              = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
            and lower(coalesce(ba.contact_person, ba.contact_name, '')) like '%' || v_person || '%'
        )
        or exists (
          select 1
          from public.delivery_addresses da
          where da.company_id = c.id
            and lower(coalesce(da.contact_person, '')) like '%' || v_person || '%'
        )
      );

    if cardinality(v_filtered) = 1 then
      return v_filtered;
    end if;
  end if;

  return v_ids;
end;
$$;

revoke all on function public.whatsapp_narrow_company_ids_by_identity_clues(uuid[], jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_narrow_company_ids_by_identity_clues(uuid[], jsonb) to service_role;

create or replace function public.whatsapp_resolve_governed_customer(
  p_contact_id uuid,
  p_candidate jsonb default '{}'::jsonb
)
returns table (
  company_id uuid,
  business_name text,
  gst_number text,
  payment_terms text,
  is_frozen boolean,
  resolution_status text,
  match_method text,
  confidence numeric,
  details jsonb
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_contact public.whatsapp_contacts%rowtype;
  v_phone text;
  v_candidate_gst text;
  v_candidate_name text;
  v_candidate_company_id uuid;
  v_gst_company_ids uuid[];
  v_name_company_ids uuid[];
  v_auth_company_ids uuid[];
  v_phone_company_ids uuid[];
  v_target_company_id uuid;
  v_company public.companies%rowtype;
  v_method text;
  v_has_explicit_candidate boolean := false;
  v_body_phone text;
  v_body_company_ids uuid[];
  v_body_phone_company_id uuid;
  v_gst_explicit_company_id uuid;
begin
  select * into v_contact from public.whatsapp_contacts where id = p_contact_id;
  if not found then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'UNRESOLVED'::text, 'CONTACT_NOT_FOUND'::text, 0.0::numeric,
      jsonb_build_object('error', 'contact not found');
    return;
  end if;

  v_phone := lower(regexp_replace(coalesce(v_contact.phone_number, ''), '\D', '', 'g'));

  -- Priority 0: Explicit candidate company_id if provided
  if p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    if nullif(btrim(coalesce(p_candidate->>'company_id', '')), '') is not null then
      v_has_explicit_candidate := true;

      begin
        v_candidate_company_id := (p_candidate->>'company_id')::uuid;
      exception when others then
        v_candidate_company_id := null;
      end;

      if v_candidate_company_id is not null then
        select * into v_company
        from public.companies c
        where c.id = v_candidate_company_id
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if found then
          v_target_company_id := v_company.id;
          v_method := 'EXPLICIT_CANDIDATE_COMPANY_ID';
        else
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'UNRESOLVED'::text, 'EXPLICIT_COMPANY_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
            jsonb_build_object('candidate_company_id', v_candidate_company_id);
          return;
        end if;
      else
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'UNRESOLVED'::text, 'INVALID_COMPANY_ID_FORMAT'::text, 0.0::numeric,
          jsonb_build_object('candidate_company_id', p_candidate->>'company_id');
        return;
      end if;
    end if;
  end if;


  -- MC#631: message-body customer phone (distinct from submitting sender phone).
  if v_target_company_id is null and p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    v_body_phone := public.whatsapp_normalize_identity_phone(coalesce(
      nullif(btrim(p_candidate->>'customer_phone'), ''),
      nullif(btrim(p_candidate->>'body_phone'), ''),
      nullif(btrim(p_candidate->>'message_phone'), ''),
      nullif(btrim(p_candidate->>'client_phone'), ''),
      ''));
    if length(v_body_phone) >= 10 and v_body_phone is distinct from v_phone then
      v_has_explicit_candidate := true;
      v_body_company_ids := public.whatsapp_match_companies_by_normalized_phone(v_body_phone);
      if cardinality(v_body_company_ids) = 1 then
        v_body_phone_company_id := v_body_company_ids[1];
        v_method := 'MESSAGE_BODY_PHONE_MATCH';
      elsif cardinality(v_body_company_ids) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'AMBIGUOUS'::text, 'MULTIPLE_BODY_PHONE_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('body_phone', v_body_phone, 'matched_company_ids', to_jsonb(v_body_company_ids));
        return;
      elsif cardinality(v_body_company_ids) = 0 then
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'UNRESOLVED'::text, 'BODY_PHONE_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
          jsonb_build_object('body_phone', v_body_phone);
        return;
      end if;
    end if;
  end if;

  -- Priority 1: Explicit candidate GST match (evaluated even when body phone already matched)
  if p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    if nullif(btrim(coalesce(p_candidate->>'gst_number', '')), '') is not null then
      v_has_explicit_candidate := true;
      v_candidate_gst := upper(regexp_replace(p_candidate->>'gst_number', '\s', '', 'g'));

      -- 15-character Indian GSTIN format check matching uq_companies_gst_number_normalized index predicate
      if v_candidate_gst ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
        select coalesce(array_agg(distinct c.id), '{}'::uuid[])
        into v_gst_company_ids
        from public.companies c
        where upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_candidate_gst
          and c.gst_number is not null
          and upper(regexp_replace(c.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if cardinality(v_gst_company_ids) = 1 then
          v_gst_explicit_company_id := v_gst_company_ids[1];
          if v_method is null then
            v_method := 'EXACT_GST_MATCH';
          end if;
        elsif cardinality(v_gst_company_ids) > 1 then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'MULTIPLE_GST_MATCHES'::text, 0.5::numeric,
            jsonb_build_object('candidate_gst', v_candidate_gst, 'matched_company_ids', to_jsonb(v_gst_company_ids));
          return;
        else
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'UNRESOLVED'::text, 'EXPLICIT_GST_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
            jsonb_build_object('candidate_gst', v_candidate_gst);
          return;
        end if;
      elsif length(v_candidate_gst) >= 15 then
        -- Bounded fallback for legacy non-standard alphanumeric GST formats
        select coalesce(array_agg(distinct c.id), '{}'::uuid[])
        into v_gst_company_ids
        from public.companies c
        where upper(regexp_replace(coalesce(c.gst_number, ''), '[^a-zA-Z0-9]', '', 'g')) = upper(regexp_replace(v_candidate_gst, '[^a-zA-Z0-9]', '', 'g'))
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if cardinality(v_gst_company_ids) = 1 then
          v_gst_explicit_company_id := v_gst_company_ids[1];
          if v_method is null then
            v_method := 'EXACT_GST_MATCH';
          end if;
        elsif cardinality(v_gst_company_ids) > 1 then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'MULTIPLE_GST_MATCHES'::text, 0.5::numeric,
            jsonb_build_object('candidate_gst', v_candidate_gst, 'matched_company_ids', to_jsonb(v_gst_company_ids));
          return;
        else
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'UNRESOLVED'::text, 'EXPLICIT_GST_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
            jsonb_build_object('candidate_gst', v_candidate_gst);
          return;
        end if;
      else
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'UNRESOLVED'::text, 'MALFORMED_OR_SHORT_GST'::text, 0.0::numeric,
          jsonb_build_object('candidate_gst', p_candidate->>'gst_number');
        return;
      end if;
    end if;
  end if;

  if v_body_phone_company_id is not null
     and v_gst_explicit_company_id is not null
     and v_body_phone_company_id is distinct from v_gst_explicit_company_id then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'AMBIGUOUS'::text, 'CONTRADICTORY_EXPLICIT_CUSTOMER_CLUES'::text, 0.0::numeric,
      jsonb_build_object(
        'body_phone_company_id', v_body_phone_company_id,
        'gst_company_id', v_gst_explicit_company_id,
        'candidate', coalesce(p_candidate, '{}'::jsonb)
      );
    return;
  end if;

  if v_target_company_id is null then
    v_target_company_id := coalesce(v_body_phone_company_id, v_gst_explicit_company_id);
  end if;

  -- Priority 2: Explicit candidate company/business name match (CURRENT EVIDENCE OUTRANKS SENDER IDENTITY)
  if v_target_company_id is null and p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    v_candidate_name := lower(btrim(coalesce(
      nullif(btrim(coalesce(p_candidate->>'company_name', '')), ''),
      nullif(btrim(coalesce(p_candidate->>'business_name', '')), ''),
      nullif(btrim(coalesce(p_candidate->>'name', '')), ''),
      ''
    )));

    if v_candidate_name <> '' then
      v_has_explicit_candidate := true;

      if length(v_candidate_name) >= 3 then
        select coalesce(array_agg(distinct c.id), '{}'::uuid[])
        into v_name_company_ids
        from public.companies c
        where lower(btrim(c.business_name)) = v_candidate_name
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if cardinality(v_name_company_ids) = 1 then
          v_target_company_id := v_name_company_ids[1];
          v_method := 'EXACT_NAME_MATCH';
        elsif cardinality(v_name_company_ids) > 1 then
          v_name_company_ids := public.whatsapp_narrow_company_ids_by_identity_clues(v_name_company_ids, p_candidate);
          if cardinality(v_name_company_ids) = 1 then
            v_target_company_id := v_name_company_ids[1];
            v_method := 'PROGRESSIVE_NAME_LOCATION_PERSON_MATCH';
          else
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'MULTIPLE_NAME_MATCHES'::text, 0.5::numeric,
            jsonb_build_object('candidate_name', v_candidate_name, 'matched_company_ids', to_jsonb(v_name_company_ids));
          return;
          end if;
        else
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'UNRESOLVED'::text, 'EXPLICIT_NAME_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
            jsonb_build_object('candidate_name', v_candidate_name);
          return;
        end if;
      else
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'UNRESOLVED'::text, 'EXPLICIT_NAME_TOO_SHORT'::text, 0.0::numeric,
          jsonb_build_object('candidate_name', v_candidate_name);
        return;
      end if;
    end if;
  end if;

  -- If an explicit customer candidate was specified in current message but failed to match, FAIL CLOSED.
  -- Do NOT fall back to the submitting sender phone or sender authorization when the message explicitly identified a company!
  if v_has_explicit_candidate and v_target_company_id is null then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'UNRESOLVED'::text, 'EXPLICIT_CANDIDATE_UNRESOLVED'::text, 0.0::numeric,
      jsonb_build_object('candidate', coalesce(p_candidate, '{}'::jsonb));
    return;
  end if;

  -- Priority 3: Active sender commercial authorization (WA-6) (Only when NO explicit candidate was provided in message)
  -- EMPLOYEE-RELAY SAFETY: Verified active Oasis internal staff can NEVER become commercial customer via their own authorization!
  if v_target_company_id is null
     and not exists (
       select 1 from public.users u
       where (
         u.id = v_contact.id
         or lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g')) = v_phone
         or u.email = v_contact.phone_number
         or exists (
           select 1 from public.whatsapp_contacts wc
           where wc.id = p_contact_id
             and (
               lower(regexp_replace(coalesce(wc.phone_number, ''), '\D', '', 'g')) = lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'))
               or wc.id = u.id
             )
         )
       )
       and (
         upper(coalesce(u.role, '')) in (
           'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
           'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
           'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
           'STORE_INCHARGE', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD', 'SECURITY_CONTROL',
           'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
         )
         or public.is_staff_role(u.role)
         or public.is_internal_staff(u.id)
       )
     ) then
    select coalesce(array_agg(distinct a.company_id), '{}'::uuid[])
    into v_auth_company_ids
    from public.whatsapp_sender_commercial_authorizations a
    join public.companies c on c.id = a.company_id
    where a.contact_id = p_contact_id
      and a.status = 'ACTIVE'
      and a.valid_until > statement_timestamp()
      and lower(coalesce(c.status, '')) in ('active', 'approved');

    if cardinality(v_auth_company_ids) = 1 then
      v_target_company_id := v_auth_company_ids[1];
      v_method := 'ACTIVE_COMMERCIAL_AUTHORIZATION';
    elsif cardinality(v_auth_company_ids) > 1 then
      return query select
        null::uuid, null::text, null::text, null::text, false,
        'AMBIGUOUS'::text, 'MULTIPLE_ACTIVE_AUTHORIZATIONS'::text, 0.5::numeric,
        jsonb_build_object('matched_company_ids', to_jsonb(v_auth_company_ids));
      return;
    end if;
  end if;

  -- Priority 4: Exact sender phone match on active company / branches / approved B2B application
  -- EMPLOYEE-RELAY SAFETY: Verified active Oasis internal staff phone can NEVER become commercial customer!
  if v_target_company_id is null and length(v_phone) >= 10
     and not exists (
       select 1 from public.users u
       where (
         u.id = v_contact.id
         or lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g')) = v_phone
         or u.email = v_contact.phone_number
         or exists (
           select 1 from public.whatsapp_contacts wc
           where wc.id = p_contact_id
             and (
               lower(regexp_replace(coalesce(wc.phone_number, ''), '\D', '', 'g')) = lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'))
               or wc.id = u.id
             )
         )
       )
       and (
         upper(coalesce(u.role, '')) in (
           'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
           'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
           'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
           'STORE_INCHARGE', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD', 'SECURITY_CONTROL',
           'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
         )
         or public.is_staff_role(u.role)
         or public.is_internal_staff(u.id)
       )
     ) then
    -- Stage A: Exact indexed equality check on primary tables
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_phone_company_ids
    from public.companies c
    where lower(coalesce(c.status, '')) in ('active', 'approved')
      and (
        c.phone = v_phone
        or exists (
          select 1 from public.delivery_addresses da
          where da.company_id = c.id
            and da.contact_phone = v_phone
        )
        or exists (
          select 1 from public.b2b_applications ba
          where ba.status = 'approved'
            and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g')) = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
            and (ba.contact_phone = v_phone or ba.mobile_number = v_phone)
        )
      );

    if cardinality(v_phone_company_ids) = 1 then
      v_target_company_id := v_phone_company_ids[1];
      v_method := 'EXACT_PHONE_MATCH';
    elsif cardinality(v_phone_company_ids) > 1 then
      return query select
        null::uuid, null::text, null::text, null::text, false,
        'AMBIGUOUS'::text, 'MULTIPLE_PHONE_MATCHES'::text, 0.5::numeric,
        jsonb_build_object('phone', v_phone, 'matched_company_ids', to_jsonb(v_phone_company_ids));
      return;
    else
      -- Stage B: Bounded legacy formatted-phone fallback (runs only when exact indexed match yields 0 rows)
      select coalesce(array_agg(distinct c.id), '{}'::uuid[])
      into v_phone_company_ids
      from public.companies c
      where lower(coalesce(c.status, '')) in ('active', 'approved')
        and (
          lower(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g')) = v_phone
          or exists (
            select 1 from public.delivery_addresses da
            where da.company_id = c.id
              and lower(regexp_replace(coalesce(da.contact_phone, ''), '\D', '', 'g')) = v_phone
          )
          or exists (
            select 1 from public.b2b_applications ba
            where ba.status = 'approved'
              and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g')) = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
              and (
                lower(regexp_replace(coalesce(ba.contact_phone, ''), '\D', '', 'g')) = v_phone
                or lower(regexp_replace(coalesce(ba.mobile_number, ''), '\D', '', 'g')) = v_phone
              )
          )
        );

      if cardinality(v_phone_company_ids) = 1 then
        v_target_company_id := v_phone_company_ids[1];
        v_method := 'EXACT_PHONE_MATCH';
      elsif cardinality(v_phone_company_ids) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'AMBIGUOUS'::text, 'MULTIPLE_PHONE_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('phone', v_phone, 'matched_company_ids', to_jsonb(v_phone_company_ids));
        return;
      end if;
    end if;
  end if;

  -- Return final resolution
  if v_target_company_id is not null then
    select * into v_company from public.companies where id = v_target_company_id;
    if not found or lower(coalesce(v_company.status, '')) not in ('active', 'approved') then
      return query select
        null::uuid, null::text, null::text, null::text, false,
        'UNRESOLVED'::text, 'COMPANY_NOT_ACTIVE'::text, 0.0::numeric,
        jsonb_build_object('company_id', v_target_company_id);
      return;
    end if;

    return query select
      v_company.id,
      v_company.business_name,
      v_company.gst_number,
      v_company.payment_terms,
      coalesce(v_company.is_frozen, false),
      'RESOLVED'::text,
      v_method,
      1.0::numeric,
      jsonb_build_object(
        'company_id', v_company.id,
        'business_name', v_company.business_name,
        'gst_number', v_company.gst_number,
        'payment_terms', v_company.payment_terms,
        'is_frozen', v_company.is_frozen,
        'status', v_company.status,
        'match_method', v_method
      );
    return;
  end if;

  return query select
    null::uuid, null::text, null::text, null::text, false,
    'UNRESOLVED'::text, 'NO_MATCH'::text, 0.0::numeric,
    jsonb_build_object('contact_phone', v_phone, 'candidate', coalesce(p_candidate, '{}'::jsonb));
end;
$$;

revoke all on function public.whatsapp_resolve_governed_customer(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_resolve_governed_customer(uuid, jsonb) to service_role;

create or replace function public.promote_sales_order_draft_to_order_governed_v1(
  p_draft_id uuid, p_expected_extraction_request_key text, p_actor_id uuid,
  p_actor_name text, p_review_notes text DEFAULT NULL, p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (draft_id uuid, promoted_order_id uuid, order_number text, already_promoted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
#variable_conflict use_column
DECLARE v_draft public.sales_order_drafts%rowtype; v_order_id uuid; v_order_number text;
  v_line record; v_qty numeric; v_lines int := 0;
BEGIN
  SELECT * INTO v_draft FROM public.sales_order_drafts d WHERE d.id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_draft.extraction_request_key IS DISTINCT FROM btrim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  IF v_draft.promoted_order_id IS NOT NULL THEN
    SELECT o.order_number INTO v_order_number FROM public.orders o WHERE o.id = v_draft.promoted_order_id;
    RETURN QUERY SELECT p_draft_id, v_draft.promoted_order_id, v_order_number, true; RETURN;
  END IF;
  IF v_draft.status <> 'UNDER_REVIEW' OR v_draft.company_id IS NULL THEN RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE = 'P0001'; END IF;
    if upper(coalesce(p_metadata->>'readiness_gate', 'FULL')) = 'SO_RECORDABLE' then
    perform public.validate_sales_order_so_recordable_readiness(v_draft.readiness_dimensions);
  else
    perform public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
  end if;
  PERFORM 1 FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id FOR UPDATE;
  SELECT count(*) INTO v_lines FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id
    AND l.product_id IS NOT NULL AND coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity, 0) > 0;
  IF v_lines = 0 THEN RAISE EXCEPTION 'DRAFT_HAS_NO_VALID_LINES' USING ERRCODE = 'P0001'; END IF;

  INSERT INTO public.sales_order_creation_scopes(backend_pid, transaction_id, authority)
  VALUES (pg_backend_pid(), txid_current(), 'WHATSAPP_DRAFT_PROMOTION')
  ON CONFLICT (backend_pid, transaction_id) DO UPDATE
    SET authority = EXCLUDED.authority, created_at = statement_timestamp();

  INSERT INTO public.orders(company_id, status, order_origin, payment_status, tracking_token)
  VALUES (v_draft.company_id, 'submitted', 'WHATSAPP', 'awaiting_receipt', encode(extensions.gen_random_bytes(16), 'hex'))
  RETURNING id, public.orders.order_number INTO v_order_id, v_order_number;

  DELETE FROM public.sales_order_creation_scopes
  WHERE backend_pid = pg_backend_pid() AND transaction_id = txid_current();
  FOR v_line IN SELECT l.* FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id ORDER BY l.line_index LOOP
    v_qty := coalesce(v_line.operator_quantity, v_line.normalized_quantity, v_line.raw_quantity, 0);
    IF v_line.product_id IS NOT NULL AND v_qty > 0 THEN
      INSERT INTO public.order_items(order_id, product_id, quantity, pack_size, notes)
      VALUES (v_order_id, v_line.product_id, v_qty, coalesce(v_line.normalized_unit, v_line.raw_unit), left(coalesce(v_line.product_name, ''), 500));
    END IF;
  END LOOP;
  PERFORM public.restore_order_financials(v_order_id);
  -- Establish the canonical draft link inside this transaction before freezing
  -- the version. The intermediate state is not visible outside the transaction.
  UPDATE public.sales_order_drafts d
     SET promoted_order_id = v_order_id, updated_by = p_actor_id, updated_at = statement_timestamp()
   WHERE d.id = p_draft_id;
  PERFORM public.create_sales_order_commercial_version_v1(
    v_order_id, 'WHATSAPP_DRAFT_PROMOTION', 'wa-draft:' || p_draft_id::text,
    'wa-so-version:' || p_draft_id::text, p_actor_id
  );
  PERFORM set_config(
    'app.wa3_promotion_readiness_gate',
    upper(coalesce(p_metadata->>'readiness_gate', 'FULL')),
    true
  );
  UPDATE public.sales_order_drafts d SET status = 'APPROVED_FOR_SO',
    approver_id = p_actor_id, approver_name = p_actor_name, review_notes = p_review_notes,
    updated_by = p_actor_id, updated_at = statement_timestamp() WHERE d.id = p_draft_id;
  INSERT INTO public.sales_order_draft_audit_log(draft_id, action, from_status, to_status, actor_id, actor_name, metadata)
  VALUES (p_draft_id, 'APPROVE', 'UNDER_REVIEW', 'APPROVED_FOR_SO', p_actor_id, p_actor_name,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('promoted_order_id', v_order_id));
  INSERT INTO public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  VALUES ('WA_DRAFT_PROMOTED_TO_SO', 'WhatsApp', 'orders', v_order_id::text, p_actor_id, 'high', jsonb_build_object('draft_id', p_draft_id));
  PERFORM set_config('app.wa3_promotion_readiness_gate', 'FULL', true);
  RETURN QUERY SELECT p_draft_id, v_order_id, v_order_number, false;
END;
$$;

create or replace function public.wa3_assert_draft_ready_for_promotion() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
  v_gate text;
begin
  if new.status = 'APPROVED_FOR_SO'
    and (tg_op = 'INSERT' or old.status is distinct from new.status or old.promoted_order_id is distinct from new.promoted_order_id) then
    if new.potential_order_id is null then
      return new;
    end if;
    v_gate := upper(coalesce(current_setting('app.wa3_promotion_readiness_gate', true), 'FULL'));
    if v_gate = 'SO_RECORDABLE' then
      v_readiness := public.evaluate_whatsapp_order_so_recordable_readiness(new.potential_order_id);
    else
      v_readiness := public.evaluate_whatsapp_order_readiness(new.potential_order_id);
    end if;
    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception 'WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED: %', v_readiness->'blocking_fields'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)
  to service_role;

create or replace function public.whatsapp_promote_autonomous_sales_order_draft_v1(
  p_draft_id uuid,
  p_expected_extraction_request_key text
)
returns table (
  draft_id uuid,
  promoted_order_id uuid,
  order_number text,
  already_promoted boolean,
  promotion_blocked boolean,
  blocking_reason text
)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
#variable_conflict use_column
declare
  v_draft public.sales_order_drafts%rowtype;
  v_promo record;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  select * into v_draft from public.sales_order_drafts d where d.id = p_draft_id;
  if not found then
    return query select p_draft_id, null::uuid, null::text, false, true, 'draft_not_found';
    return;
  end if;

  if coalesce(v_draft.extraction_request_key, '') not like 'core-b:autonomy:%' then
    return query select p_draft_id, null::uuid, null::text, false, true, 'draft_not_core_b_governed';
    return;
  end if;

  if v_draft.extraction_request_key is distinct from btrim(p_expected_extraction_request_key) then
    return query select p_draft_id, null::uuid, null::text, false, true, 'IDEMPOTENCY_KEY_MISMATCH';
    return;
  end if;

  if v_draft.promoted_order_id is not null then
    return query
    select p_draft_id, v_draft.promoted_order_id, o.order_number, true, false, null::text
    from public.orders o
    where o.id = v_draft.promoted_order_id;
    return;
  end if;

  if v_draft.status <> 'UNDER_REVIEW' or v_draft.company_id is null then
    return query select p_draft_id, null::uuid, null::text, false, true, 'DRAFT_NOT_READY';
    return;
  end if;

  if not exists (
    select 1
    from public.sales_order_draft_lines l
    where l.draft_id = p_draft_id
      and l.product_id is not null
      and coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity, 0) > 0
  ) then
    return query select p_draft_id, null::uuid, null::text, false, true, 'DRAFT_HAS_NO_VALID_LINES';
    return;
  end if;

  begin
    select * into v_promo
    from public.promote_sales_order_draft_to_order_governed_v1(
      p_draft_id,
      p_expected_extraction_request_key,
      null,
      'CORE-B_AUTONOMY',
      'Autonomous promotion from CORE-B governed draft',
      jsonb_build_object('autonomous', true, 'readiness_gate', 'SO_RECORDABLE')
    );

    return query
    select v_promo.draft_id, v_promo.promoted_order_id, v_promo.order_number, v_promo.already_promoted, false, null::text;
  exception
    when others then
      if sqlstate = 'P0001'
         and sqlerrm = any (array[
           'DRAFT_NOT_FOUND',
           'IDEMPOTENCY_KEY_MISMATCH',
           'DRAFT_NOT_READY',
           'DRAFT_HAS_NO_VALID_LINES'
         ]) then
        return query select p_draft_id, null::uuid, null::text, false, true, sqlerrm;
      end if;
      raise;
  end;
end;
$$;



create or replace function public.whatsapp_execute_autonomous_order_draft_v1(
  p_autonomy_decision_id uuid,
  p_attempt_promotion boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, extensions
as $$
declare
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_projection public.whatsapp_order_autonomy_draft_executions%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_po public.whatsapp_potential_orders%rowtype;
  v_company public.companies%rowtype;
  v_packet_text text := '';
  v_governed_facts jsonb;
  v_readiness jsonb;
  v_readiness_dims jsonb;
  v_idempotency_key text;
  v_extraction_key text;
  v_draft_id uuid;
  v_line jsonb;
  v_line_idx integer;
  v_b2b record;
  v_promo record;
  v_order_number text;
  v_blocking_reason text;
  v_event public.whatsapp_order_autonomy_draft_execution_events%rowtype;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  select * into v_projection
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  if found then
    if v_projection.execution_status = 'PROMOTED' then
      if v_projection.promoted_order_id is not null then
        select o.order_number into v_order_number from public.orders o where o.id = v_projection.promoted_order_id;
      end if;
      return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, v_order_number);
    end if;

    if v_projection.execution_status = 'PROMOTION_BLOCKED' then
      return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, null);
    end if;

    if v_projection.execution_status = 'REJECTED_NOT_ELIGIBLE' then
      return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, null);
    end if;

    if v_projection.execution_status = 'DRAFT_CREATED' and p_attempt_promotion then
      select * into v_promo
      from public.whatsapp_promote_autonomous_sales_order_draft_v1(
        v_projection.sales_order_draft_id,
        v_projection.idempotency_key
      );

      if coalesce(v_promo.promotion_blocked, false) then
        perform public.whatsapp_append_autonomy_draft_execution_event(
          p_autonomy_decision_id, 'PROMOTION_BLOCKED',
          v_projection.potential_order_id, v_projection.case_id, v_projection.packet_id, v_projection.interpretation_id,
          v_projection.sales_order_draft_id, null, v_promo.blocking_reason,
          v_projection.idempotency_key,
          v_projection.governed_facts_snapshot, v_projection.readiness_snapshot
        );
        perform public.whatsapp_record_autonomous_so_promotion_blocked_v1(
          v_projection.case_id,
          v_projection.interpretation_id,
          p_autonomy_decision_id,
          v_projection.sales_order_draft_id,
          v_promo.blocking_reason
        );
        select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
        return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, null);
      end if;

      if v_promo.promoted_order_id is not null then
        perform public.whatsapp_finalize_autonomous_so_promotion_v1(
          p_autonomy_decision_id,
          v_projection.sales_order_draft_id,
          v_promo.promoted_order_id,
          v_promo.order_number,
          v_projection.idempotency_key,
          v_projection.governed_facts_snapshot,
          v_projection.readiness_snapshot
        );
        select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
        return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, v_promo.order_number);
      end if;
    end if;

    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, null);
  end if;

  select * into v_decision
  from public.whatsapp_order_autonomy_decisions
  where id = p_autonomy_decision_id
  for update;

  if not found then
    raise exception 'autonomy decision not found' using errcode = 'P0002';
  end if;

  v_idempotency_key := 'core-b:autonomy:' || p_autonomy_decision_id::text;
  v_extraction_key := v_idempotency_key;
  v_governed_facts := v_decision.governed_facts;

  if v_decision.autonomy_outcome <> 'AUTO_ELIGIBLE' then
    perform public.whatsapp_append_autonomy_draft_execution_event(
      p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
      v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
      null, null, 'autonomy_outcome_not_auto_eligible:' || v_decision.autonomy_outcome,
      v_idempotency_key,
      v_governed_facts, v_decision.readiness_snapshot
    );
    select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
  end if;

  if not public.whatsapp_autonomy_decision_is_current(p_autonomy_decision_id) then
    perform public.whatsapp_append_autonomy_draft_execution_event(
      p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
      v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
      null, null, 'stale_autonomy_decision_superseded',
      v_idempotency_key,
      v_governed_facts, v_decision.readiness_snapshot
    );
    select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
  end if;

  if v_decision.potential_order_id is null then
    raise exception 'autonomy decision missing potential order' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('core-b-draft:' || v_decision.packet_id::text, 0));

  select * into v_projection
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  if found then
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, true, null);
  end if;

  select * into v_po
  from public.whatsapp_potential_orders
  where id = v_decision.potential_order_id
  for update;

  if not public.whatsapp_core_b_governed_facts_draft_eligible(v_governed_facts) then
    v_blocking_reason := case
      when coalesce(v_governed_facts->'customer'->>'company_id', '') = '' then 'governed_customer_company_missing'
      when jsonb_typeof(v_governed_facts->'order_lines') <> 'array'
        or jsonb_array_length(v_governed_facts->'order_lines') = 0 then 'governed_order_lines_missing'
      when coalesce(v_governed_facts->'branch'->>'delivery_address_id', '') = '' then 'delivery_details_pending_hold'
      else 'governed_facts_incomplete_for_draft'
    end;
    perform public.whatsapp_append_autonomy_draft_execution_event(
      p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
      v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
      null, null, v_blocking_reason,
      v_idempotency_key,
      v_governed_facts, public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts)
    );
    select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
  end if;

  select d.id into v_draft_id
  from public.sales_order_drafts d
  where d.packet_id = v_decision.packet_id
    and d.status <> 'REJECTED'
  limit 1;

  if v_draft_id is not null and not exists (
    select 1 from public.whatsapp_order_autonomy_draft_executions e
    where e.sales_order_draft_id = v_draft_id
      and e.autonomy_decision_id = p_autonomy_decision_id
  ) then
    perform public.whatsapp_append_autonomy_draft_execution_event(
      p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
      v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
      null, null, 'conflicting_active_draft_for_packet',
      v_idempotency_key,
      v_governed_facts, public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts)
    );
    select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
  end if;

  if v_draft_id is null then
    select * into v_company
    from public.companies
    where id = (v_governed_facts->'customer'->>'company_id')::uuid;

    if not found then
      perform public.whatsapp_append_autonomy_draft_execution_event(
        p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
        v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
        null, null, 'governed_customer_company_not_found',
        v_idempotency_key,
        v_governed_facts, public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts)
      );
      select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
      return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
    end if;

    v_blocking_reason := null;

    for v_line, v_line_idx in
      select value, ordinality::integer
      from jsonb_array_elements(v_governed_facts->'order_lines') with ordinality
    loop
      if nullif(btrim(coalesce(v_line->>'product_id', '')), '') is null then
        v_blocking_reason := 'missing_product_id_line_' || v_line_idx::text;
        exit;
      end if;

      if coalesce((v_line->>'quantity')::numeric, 0) <= 0 then
        v_blocking_reason := 'missing_quantity_line_' || v_line_idx::text;
        exit;
      end if;

      if nullif(btrim(coalesce(v_line->>'uom', v_line->>'unit', '')), '') is null then
        v_blocking_reason := 'missing_uom_line_' || v_line_idx::text;
        exit;
      end if;

      select * into v_b2b
      from public.customer_resolve_buyer_product_authority_v1(
        v_company.id,
        (v_line->>'product_id')::uuid
      );

      if not coalesce(v_b2b.is_available, false) then
        v_blocking_reason := 'missing_b2b_product_authority_line_' || v_line_idx::text;
        exit;
      end if;
    end loop;

    if v_blocking_reason is not null then
      perform public.whatsapp_append_autonomy_draft_execution_event(
        p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
        v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
        null, null, v_blocking_reason,
        v_idempotency_key,
        v_governed_facts, public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts)
      );
      select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
      return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null);
    end if;
  end if;

  v_readiness := public.evaluate_whatsapp_order_so_recordable_readiness(v_decision.potential_order_id);
  if not coalesce((v_readiness->>'ready')::boolean, false) then
    perform public.whatsapp_append_autonomy_draft_execution_event(
      p_autonomy_decision_id, 'REJECTED_NOT_ELIGIBLE',
      v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
      null, null, 'readiness_no_longer_true',
      v_idempotency_key,
      v_governed_facts, v_readiness
    );
    select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
    return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, null)
      || jsonb_build_object('readiness', v_readiness);
  end if;

  if v_draft_id is null then
    v_readiness_dims := public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts);

    select coalesce(string_agg(wm.content, E'\n' order by wm.packet_sequence nulls last, wm.created_at), '')
    into v_packet_text
    from public.whatsapp_messages wm
    where wm.packet_id = v_decision.packet_id
      and lower(wm.direction) = 'inbound';

    insert into public.sales_order_drafts (
      packet_id,
      extraction_request_key,
      status,
      company_id,
      company_name,
      readiness_overall_score,
      readiness_dimensions,
      original_whatsapp_text,
      ai_draft_snapshot,
      potential_order_id,
      created_by,
      updated_by
    ) values (
      v_decision.packet_id,
      v_extraction_key,
      'UNDER_REVIEW',
      v_company.id,
      v_company.business_name,
      100,
      v_readiness_dims,
      left(coalesce(v_packet_text, ''), 10000),
      jsonb_build_object(
        'source', 'CORE_B_AUTONOMY',
        'autonomy_decision_id', v_decision.id,
        'governed_facts', v_governed_facts,
        'branch', v_governed_facts->'branch',
        'payment_terms', v_governed_facts->'customer'->>'payment_terms'
      ),
      v_decision.potential_order_id,
      null,
      null
    )
    returning id into v_draft_id;

    for v_line, v_line_idx in
      select value, ordinality::integer
      from jsonb_array_elements(v_governed_facts->'order_lines') with ordinality
    loop
      select * into v_b2b
      from public.customer_resolve_buyer_product_authority_v1(
        v_company.id,
        (v_line->>'product_id')::uuid
      );

      insert into public.sales_order_draft_lines (
        draft_id,
        line_index,
        product_id,
        product_name,
        sku,
        raw_quantity,
        raw_unit,
        normalized_quantity,
        normalized_unit,
        operator_quantity,
        product_confidence,
        quantity_confidence,
        ai_line_snapshot
      ) values (
        v_draft_id,
        coalesce((v_line->>'line_number')::integer, v_line_idx) - 1,
        (v_line->>'product_id')::uuid,
        coalesce(v_line->>'product_name', v_b2b.product_name),
        coalesce(v_line->>'sku', v_b2b.sku),
        (v_line->>'quantity')::numeric,
        v_line->>'uom',
        (v_line->>'quantity')::numeric,
        v_line->>'uom',
        (v_line->>'quantity')::numeric,
        1.0,
        1.0,
        jsonb_build_object(
          'source', 'CORE_B_GOVERNED',
          'selling_price', v_b2b.selling_price,
          'currency', v_b2b.currency,
          'gst_rate', v_b2b.gst_rate,
          'pack_size', v_line->>'pack_size',
          'moq', v_line->>'moq'
        )
      );
    end loop;

    insert into public.sales_order_draft_audit_log (
      draft_id, action, from_status, to_status, actor_name, metadata
    ) values (
      v_draft_id, 'CREATE', null, 'UNDER_REVIEW', 'CORE-B_AUTONOMY',
      jsonb_build_object(
        'autonomy_decision_id', v_decision.id,
        'autonomous', true,
        'governed_facts', v_governed_facts
      )
    );
  end if;

  if v_decision.case_id is not null then
    update public.whatsapp_communication_cases
    set sales_order_draft_id = v_draft_id,
        status = 'DRAFTED',
        next_action = case when p_attempt_promotion then 'AUTONOMOUS_SO_PROMOTION_PENDING' else 'Review governed Sales Order Draft' end,
        updated_at = statement_timestamp()
    where id = v_decision.case_id;

    insert into public.whatsapp_case_events(case_id, event_type, actor_type, correlation_key, resulting_state, metadata)
    values (
      v_decision.case_id, 'AUTONOMOUS_DRAFT_CREATED', 'SYSTEM',
      'core-b-draft:' || v_decision.interpretation_id::text,
      jsonb_build_object('sales_order_draft_id', v_draft_id, 'status', 'DRAFTED'),
      jsonb_build_object('autonomy_decision_id', v_decision.id, 'autonomous', true)
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  perform set_config('app.wa1_governed_mutation', 'on', true);
  update public.whatsapp_potential_orders
  set sales_order_draft_id = v_draft_id,
      next_action = case when p_attempt_promotion then 'AUTONOMOUS_SO_PROMOTION' else 'DRAFT_LINKED' end,
      updated_at = statement_timestamp()
  where id = v_decision.potential_order_id;
  perform set_config('app.wa1_governed_mutation', 'off', true);

  perform public.whatsapp_append_autonomy_draft_execution_event(
    p_autonomy_decision_id, 'DRAFT_CREATED',
    v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
    v_draft_id, null, null,
    v_idempotency_key,
    v_governed_facts, v_readiness
  );

  if p_attempt_promotion then
    select * into v_promo
    from public.whatsapp_promote_autonomous_sales_order_draft_v1(v_draft_id, v_extraction_key);

    if coalesce(v_promo.promotion_blocked, false) then
      perform public.whatsapp_append_autonomy_draft_execution_event(
        p_autonomy_decision_id, 'PROMOTION_BLOCKED',
        v_decision.potential_order_id, v_decision.case_id, v_decision.packet_id, v_decision.interpretation_id,
        v_draft_id, null, v_promo.blocking_reason,
        v_idempotency_key,
        v_governed_facts, v_readiness
      );
      perform public.whatsapp_record_autonomous_so_promotion_blocked_v1(
        v_decision.case_id,
        v_decision.interpretation_id,
        p_autonomy_decision_id,
        v_draft_id,
        v_promo.blocking_reason
      );
    elsif v_promo.promoted_order_id is not null then
      perform public.whatsapp_finalize_autonomous_so_promotion_v1(
        p_autonomy_decision_id, v_draft_id, v_promo.promoted_order_id, v_promo.order_number,
        v_idempotency_key, v_governed_facts, v_readiness
      );
      v_order_number := v_promo.order_number;
    end if;
  end if;

  select * into v_projection from public.whatsapp_order_autonomy_draft_executions where autonomy_decision_id = p_autonomy_decision_id;
  return public.whatsapp_build_autonomy_draft_execution_response(v_projection, false, v_order_number);
exception when others then
  perform set_config('app.wa1_governed_mutation', 'off', true);
  perform set_config('app.core_b_projection_mutation', 'off', true);
  raise;
end;
$$;



create or replace function public.whatsapp_evaluate_and_materialize_order_autonomy(
  p_packet_id uuid,
  p_interpretation_id uuid,
  p_job_id uuid default null,
  p_lease_token uuid default null,
  p_packet_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_existing_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_potential_order_id uuid;
  v_po public.whatsapp_potential_orders%rowtype;
  v_primary_msg_id uuid;
  v_customer_rec record;
  v_branch_rec record;
  v_branch_status text := 'UNRESOLVED';
  v_lines jsonb;
  v_line jsonb;
  v_line_idx integer;
  v_line_rec record;
  v_governed_lines jsonb := '[]'::jsonb;
  v_all_lines_resolved boolean := true;
  v_any_missing_qty boolean := false;
  v_any_ambiguous_sku boolean := false;
  v_any_ambiguous_uom boolean := false;
  v_any_below_moq boolean := false;
  v_is_moq_policy_only boolean;
  v_blocking_reasons text[] := '{}'::text[];
  v_decision_reasons text[] := '{}'::text[];
  v_governed_facts jsonb := '{}'::jsonb;
  v_readiness jsonb;
  v_is_ready boolean := false;
  v_outcome text;
  v_confidence numeric;
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_event_key text;
  v_confirmed_customer_id uuid;
  v_customer_candidate jsonb;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  -- Idempotency check: if decision already recorded for this exact interpretation, return it
  select * into v_existing_decision
  from public.whatsapp_order_autonomy_decisions
  where packet_id = p_packet_id and interpretation_id = p_interpretation_id;

  if found then
    return jsonb_build_object(
      'decision_id', v_existing_decision.id,
      'autonomy_outcome', v_existing_decision.autonomy_outcome,
      'case_id', v_existing_decision.case_id,
      'potential_order_id', v_existing_decision.potential_order_id,
      'packet_id', v_existing_decision.packet_id,
      'decision_reasons', to_jsonb(v_existing_decision.decision_reasons),
      'blocking_reasons', to_jsonb(v_existing_decision.blocking_reasons),
      'governed_facts', v_existing_decision.governed_facts,
      'readiness', v_existing_decision.readiness_snapshot,
      'human_decision_required', (v_existing_decision.autonomy_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED')),
      'idempotent_replay', true
    );
  end if;

  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  if not found then raise exception 'WhatsApp packet not found' using errcode = 'P0002'; end if;

  select * into v_ai from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id and packet_id = p_packet_id;
  if not found then raise exception 'packet AI interpretation not found' using errcode = 'P0002'; end if;

  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
  if not found then raise exception 'packet contact not found' using errcode = 'P0002'; end if;

  v_conclusion := case
    when jsonb_typeof(v_ai.interpretation->'conclusion') = 'object' then v_ai.interpretation->'conclusion'
    else '{}'::jsonb
  end;

  v_confidence := case
    when jsonb_typeof(v_ai.interpretation->'confidence') = 'number' then (v_ai.interpretation->>'confidence')::numeric
    else 0.0::numeric
  end;

  v_intent := upper(coalesce(nullif(btrim(v_conclusion->>'intent'), ''), 'UNCLEAR'));

  -- Locate or create communication case
  select * into v_case from public.whatsapp_communication_cases where packet_id = p_packet_id for update;

  -- Resolve or bridge potential order
  if v_case.id is not null then
    v_potential_order_id := public.whatsapp_case_potential_order_id(v_case.id);
  end if;

  if v_potential_order_id is null then
    -- Match by inbound messages on this packet deterministically
    select im.id into v_primary_msg_id
    from public.whatsapp_messages wm
    join public.whatsapp_inbound_messages im on im.provider_message_id = wm.provider_message_id
    where wm.packet_id = p_packet_id and lower(wm.direction) = 'inbound'
    order by wm.packet_sequence nulls last, coalesce(wm.message_timestamp, wm.created_at), wm.created_at, wm.id
    limit 1;

    if v_primary_msg_id is not null and (v_intent in ('ORDER', 'NEW_ORDER') or v_intent = 'UNCLEAR' or v_confidence < 0.50) then
      select * into v_po from public.capture_whatsapp_potential_order(
        v_primary_msg_id,
        (v_intent in ('ORDER', 'NEW_ORDER')),
        (v_intent = 'UNCLEAR' or v_confidence < 0.50),
        jsonb_build_object('packet_id', p_packet_id, 'interpretation_id', p_interpretation_id)
      );
      v_potential_order_id := v_po.id;
    end if;
  else
    select * into v_po from public.whatsapp_potential_orders where id = v_potential_order_id for update;
    if v_primary_msg_id is null then
      v_primary_msg_id := v_po.source_message_id;
    end if;
  end if;

  if v_primary_msg_id is null then
    select im.id into v_primary_msg_id
    from public.whatsapp_messages wm
    join public.whatsapp_inbound_messages im on im.provider_message_id = wm.provider_message_id
    where wm.packet_id = p_packet_id and lower(wm.direction) = 'inbound'
    order by wm.packet_sequence nulls last, coalesce(wm.message_timestamp, wm.created_at), wm.created_at, wm.id
    limit 1;
  end if;

  -- 1. Intent Validation
  if v_intent not in ('ORDER', 'NEW_ORDER') then
    if v_intent in ('ENQUIRY', 'SPECIFICATION_QUERY', 'SPECIFICATION', 'DELIVERY_QUERY', 'DISPATCH') then
      v_outcome := 'CLARIFICATION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'non_order_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'intent_is_not_commercial_order');
    elsif v_intent in ('COMPLAINT', 'ACCOUNT_QUERY', 'FINANCE', 'PAYMENT_ADVICE') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'support_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'intent_requires_human_support');
    elsif v_intent in ('CANCELLATION', 'ORDER_CHANGE', 'AMENDMENT') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'order_modification_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'order_change_requires_human_verification');
    else
      if v_intent = 'UNCLEAR'
         and v_confidence >= 0.50
         and (
           upper(coalesce(nullif(btrim(v_conclusion->>'reply_clearance'), ''), '')) = 'CLARIFICATION_REQUIRED'
           or (
             jsonb_typeof(v_conclusion->'explicit_facts') = 'array'
             and jsonb_array_length(v_conclusion->'explicit_facts') > 0
           )
         ) then
        v_outcome := 'CLARIFICATION_REQUIRED';
        v_decision_reasons := array_append(v_decision_reasons, 'unclear_intent_requires_clarification');
        v_blocking_reasons := array_append(v_blocking_reasons, 'unclear_intent');
      else
        v_outcome := 'FAILED_INTERPRETATION';
        v_decision_reasons := array_append(v_decision_reasons, 'unclear_or_unsupported_intent');
        v_blocking_reasons := array_append(v_blocking_reasons, 'unclear_intent');
      end if;
    end if;
  end if;

  -- 2. Customer Validation (Deterministic, fail-closed)
  --
  -- MC#629 activation repair: a CONFIRMED COMMERCIAL_CUSTOMER case identity
  -- (written only by the real, permission-gated whatsapp_confirm_case_identity
  -- RPC) is governed, human-verified evidence and takes priority over the
  -- AI's own extracted candidate. This is resolver Priority 0 (explicit
  -- company_id) exactly as whatsapp_resolve_governed_customer already
  -- defines it -- no resolver change. When no such identity exists, behavior
  -- is byte-for-byte identical to before this migration.
  select ci.party_id into v_confirmed_customer_id
  from public.whatsapp_case_identities ci
  where ci.case_id = v_case.id
    and ci.identity_role = 'COMMERCIAL_CUSTOMER'
    and ci.resolution_status = 'CONFIRMED'
  limit 1;

  v_customer_candidate := case
    when v_confirmed_customer_id is not null then jsonb_build_object('company_id', v_confirmed_customer_id)
    when jsonb_typeof(v_conclusion->'customer') = 'object' then v_conclusion->'customer'
    else '{}'::jsonb
  end;

  select * into v_customer_rec
  from public.whatsapp_resolve_governed_customer(
    v_packet.contact_id,
    v_customer_candidate
  );

  if v_customer_rec.resolution_status = 'RESOLVED' then
    v_governed_facts := v_governed_facts || jsonb_build_object(
      'customer', jsonb_build_object(
        'company_id', v_customer_rec.company_id,
        'business_name', v_customer_rec.business_name,
        'gst_number', v_customer_rec.gst_number,
        'payment_terms', v_customer_rec.payment_terms,
        'is_frozen', v_customer_rec.is_frozen,
        'match_method', v_customer_rec.match_method
      )
    );
    v_decision_reasons := array_append(v_decision_reasons, 'customer_resolved:' || v_customer_rec.match_method);

    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        jsonb_build_object('company_id', v_customer_rec.company_id, 'business_name', v_customer_rec.business_name),
        'resolved', 1.0, v_customer_rec.business_name,
        jsonb_build_object('match_method', v_customer_rec.match_method, 'rule_version', 'core-a-autonomy/v1'),
        true
      );
    end if;

    if v_case.id is not null then
      update public.whatsapp_communication_cases
      set company_id = v_customer_rec.company_id, updated_at = statement_timestamp()
      where id = v_case.id;

      insert into public.whatsapp_case_identities(
        case_id, identity_role, party_type, party_id, display_label, phone_e164,
        resolution_status, confidence, resolved_by, resolved_at, evidence
      ) values (
        v_case.id, 'COMMERCIAL_CUSTOMER', 'COMPANY', v_customer_rec.company_id, v_customer_rec.business_name,
        v_contact.phone_number,
        case when auth.uid() is not null then 'CONFIRMED' else 'SUGGESTED' end,
        1.0,
        auth.uid(),
        case when auth.uid() is not null then statement_timestamp() end,
        jsonb_build_array(jsonb_build_object('source', 'CORE_A_DETERMINISTIC_RESOLVER', 'method', v_customer_rec.match_method))
      )
      on conflict (case_id, identity_role) do update set
        party_id = excluded.party_id,
        display_label = excluded.display_label,
        phone_e164 = excluded.phone_e164,
        resolution_status = excluded.resolution_status,
        confidence = 1.0,
        resolved_by = excluded.resolved_by,
        resolved_at = excluded.resolved_at,
        evidence = public.whatsapp_case_identities.evidence || excluded.evidence;
    end if;

    -- Policy Check: Frozen company
    if v_customer_rec.is_frozen then
      v_blocking_reasons := array_append(v_blocking_reasons, 'customer_company_credit_frozen');
    end if;
  elsif v_customer_rec.resolution_status = 'AMBIGUOUS' then
    v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_customer_match');
    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null,
        jsonb_build_object('details', v_customer_rec.details), true
      );
    end if;
  else
    v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_customer');
    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null,
        jsonb_build_object('details', v_customer_rec.details), true
      );
    end if;
  end if;

  -- 3. Branch Validation (Deterministic)
  if v_customer_rec.company_id is not null then
    select * into v_branch_rec
    from public.whatsapp_resolve_governed_branch(
      v_customer_rec.company_id,
      case
        when jsonb_typeof(v_conclusion->'branch') = 'object' then v_conclusion->'branch'
        when jsonb_typeof(v_conclusion->'delivery_address') = 'object' then v_conclusion->'delivery_address'
        else '{}'::jsonb
      end
    );

    v_branch_status := coalesce(v_branch_rec.resolution_status, 'UNRESOLVED');

    if v_branch_rec.resolution_status = 'RESOLVED' then
      v_governed_facts := v_governed_facts || jsonb_build_object(
        'branch', jsonb_build_object(
          'delivery_address_id', v_branch_rec.delivery_address_id,
          'label', v_branch_rec.label,
          'street_address', v_branch_rec.street_address,
          'city', v_branch_rec.city,
          'pincode', v_branch_rec.pincode,
          'match_method', v_branch_rec.match_method
        )
      );
      v_decision_reasons := array_append(v_decision_reasons, 'branch_resolved:' || v_branch_rec.match_method);

      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          jsonb_build_object(
            'delivery_address_id', v_branch_rec.delivery_address_id,
            'label', v_branch_rec.label,
            'city', v_branch_rec.city,
            'pincode', v_branch_rec.pincode
          ),
          'resolved', 1.0, v_branch_rec.label,
          jsonb_build_object('match_method', v_branch_rec.match_method), true
        );
      end if;
    elsif v_branch_rec.resolution_status = 'AMBIGUOUS' then
      v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_branch_match');
      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          null, 'ambiguous', 0.5, null,
          jsonb_build_object('details', v_branch_rec.details), true
        );
      end if;
    else
      -- MC#631: missing delivery branch blocks dispatch/billing gates, not SO capture.
      v_governed_facts := v_governed_facts || jsonb_build_object('pending_holds', coalesce(v_governed_facts->'pending_holds', '[]'::jsonb) || jsonb_build_array('DELIVERY_DETAILS_PENDING'));
      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          null, 'unresolved', 0.0, null,
          jsonb_build_object('details', v_branch_rec.details), true
        );
      end if;
    end if;
  else
    v_branch_status := 'UNRESOLVED';
    v_blocking_reasons := array_append(v_blocking_reasons, 'branch_requires_customer');
  end if;

  -- 4. Order Lines Validation (Exact SKU, explicit quantity, governed UOM/pack, MOQ)
  v_lines := case
    when jsonb_typeof(v_conclusion->'order_lines') = 'array' then v_conclusion->'order_lines'
    else '[]'::jsonb
  end;

  if jsonb_array_length(v_lines) = 0 and v_intent in ('ORDER', 'NEW_ORDER') then
    v_all_lines_resolved := false;
    v_blocking_reasons := array_append(v_blocking_reasons, 'no_order_lines_extracted');
  end if;

  for v_line, v_line_idx in
    select value, ordinality::integer from jsonb_array_elements(v_lines) with ordinality
  loop
    select * into v_line_rec
    from public.whatsapp_resolve_governed_product_line(
      v_line,
      v_ai.knowledge_snapshot_id,
      v_customer_rec.company_id,
      p_packet_id
    );

    if v_line_rec.resolution_status = 'RESOLVED' then
      v_governed_lines := v_governed_lines || jsonb_build_array(jsonb_build_object(
        'line_number', v_line_idx,
        'product_id', v_line_rec.product_id,
        'sku', v_line_rec.sku,
        'product_name', v_line_rec.product_name,
        'quantity', v_line_rec.quantity,
        'uom', v_line_rec.uom,
        'pack_size', v_line_rec.pack_size,
        'moq', v_line_rec.moq,
        'moq_satisfied', v_line_rec.moq_satisfied,
        'match_method', v_line_rec.match_method
      ));
    else
      -- Governed MOQ-only policy constraints keep commercial facts explicit while routing
      -- to POLICY_APPROVAL_REQUIRED. All other non-RESOLVED lines fail closed.
      v_is_moq_policy_only := (
        not coalesce(v_line_rec.moq_satisfied, true)
        and coalesce(cardinality(v_line_rec.unresolved_reasons), 0) > 0
        and not exists (
          select 1
            from unnest(v_line_rec.unresolved_reasons) r
           where r not in (
             'below_moq_carton_constraint',
             'violates_canonical_b2b_moq_or_increment_or_carton'
           )
        )
      );

      if not v_is_moq_policy_only then
        v_all_lines_resolved := false;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_line_' || v_line_idx::text);
      end if;

      if not coalesce(v_line_rec.moq_satisfied, true)
         or 'below_moq_carton_constraint' = any(v_line_rec.unresolved_reasons)
         or 'violates_canonical_b2b_moq_or_increment_or_carton' = any(v_line_rec.unresolved_reasons) then
        v_any_below_moq := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'below_moq_line_' || v_line_idx::text);
      end if;

      if 'missing_quantity' = any(v_line_rec.unresolved_reasons)
         or 'quantity_not_evidence_proven' = any(v_line_rec.unresolved_reasons)
         or 'quantity_mismatch_with_evidence' = any(v_line_rec.unresolved_reasons) then
        v_any_missing_qty := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'missing_explicit_quantity_line_' || v_line_idx::text);
      end if;
      if exists (select 1 from unnest(v_line_rec.unresolved_reasons) r where r like '%ambiguous%') then
        v_any_ambiguous_sku := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_product' = any(v_line_rec.unresolved_reasons) then
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_unit' = any(v_line_rec.unresolved_reasons) or 'invalid_or_ambiguous_uom' = any(v_line_rec.unresolved_reasons) then
        v_any_ambiguous_uom := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_unit_line_' || v_line_idx::text);
      end if;
      if 'missing_approved_b2b_product_authority' = any(v_line_rec.unresolved_reasons) or 'product_not_available_for_buyer' = any(v_line_rec.unresolved_reasons) then
        v_blocking_reasons := array_append(v_blocking_reasons, 'missing_b2b_product_authority_line_' || v_line_idx::text);
      end if;
    end if;
  end loop;

  v_governed_facts := v_governed_facts || jsonb_build_object('order_lines', v_governed_lines);

  -- Materialise field evidence to WA-3 for product, quantity, unit_packaging, moq_carton (ONLY FOR COMMERCIAL ORDERS)
  if v_intent in ('ORDER', 'NEW_ORDER') and v_po.id is not null and v_primary_msg_id is not null then
    -- Product dimension
    if v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        v_governed_lines, 'resolved', 1.0, null,
        jsonb_build_object('line_count', jsonb_array_length(v_governed_lines), 'governed_materialisation', 'true'), true
      );
    elsif v_any_ambiguous_sku then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null,
        jsonb_build_object('raw_lines', v_lines), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null,
        jsonb_build_object('raw_lines', v_lines), true
      );
    end if;

    -- Quantity dimension (Strict: NEVER default to 1)
    if not v_any_missing_qty and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'quantity', v_primary_msg_id,
        'core-a:quantity:' || p_interpretation_id::text,
        (select jsonb_agg(l->'quantity') from jsonb_array_elements(v_governed_lines) l),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'quantity', v_primary_msg_id,
        'core-a:quantity:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;

    -- Unit Packaging dimension
    if not v_any_ambiguous_uom and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        (select jsonb_agg(l->'uom') from jsonb_array_elements(v_governed_lines) l),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    elsif v_any_ambiguous_uom then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null, '{}'::jsonb, true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;

    -- MOQ / Carton dimension
    if not v_any_below_moq and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        jsonb_build_object('moq_satisfied', true),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    elsif v_any_below_moq and not v_any_missing_qty and not v_any_ambiguous_sku and not v_any_ambiguous_uom then
      -- Explicit quantity below MOQ is a clear policy constraint, resolved as below_moq for policy approval
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        jsonb_build_object('moq_satisfied', false, 'below_moq', true),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        null, case when v_any_below_moq then 'ambiguous' else 'unresolved' end,
        0.5, null, jsonb_build_object('below_moq', v_any_below_moq), true
      );
    end if;

    -- Payment terms dimension
    if v_customer_rec.company_id is not null and v_customer_rec.payment_terms is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'payment_terms', v_primary_msg_id,
        'core-a:payment:' || p_interpretation_id::text,
        jsonb_build_object('payment_terms', v_customer_rec.payment_terms),
        'resolved', 1.0, v_customer_rec.payment_terms,
        jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'payment_terms', v_primary_msg_id,
        'core-a:payment:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;
  end if;

  -- 5. Evaluate WA-3 Readiness (ONLY FOR COMMERCIAL ORDERS)
  if v_intent in ('ORDER', 'NEW_ORDER') and v_po.id is not null then
    v_readiness := public.evaluate_whatsapp_order_so_recordable_readiness(v_po.id);
    v_is_ready := coalesce((v_readiness->>'ready')::boolean, false);
  else
    v_readiness := jsonb_build_object('ready', false, 'blocking_fields', to_jsonb(v_blocking_reasons));
    v_is_ready := false;
  end if;

  -- 6. Canonical Autonomy Outcome Derivation
  if v_outcome is null then
    if v_customer_rec.is_frozen or (v_any_below_moq and v_intent in ('ORDER', 'NEW_ORDER') and v_all_lines_resolved and not v_any_missing_qty and not v_any_ambiguous_sku and not v_any_ambiguous_uom) then
      v_outcome := 'POLICY_APPROVAL_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'policy_constraint_violated');
    elsif v_is_ready
          and v_intent in ('ORDER', 'NEW_ORDER')
          and v_customer_rec.resolution_status = 'RESOLVED'
          and v_all_lines_resolved
          and not v_any_missing_qty
          and not v_any_ambiguous_sku
          and not v_any_ambiguous_uom
          and cardinality(v_blocking_reasons) = 0 then
      v_outcome := 'AUTO_ELIGIBLE';
      v_decision_reasons := array_append(v_decision_reasons, 'so_recordable_facts_deterministically_resolved');
    elsif v_customer_rec.resolution_status = 'AMBIGUOUS'
          or exists (select 1 from unnest(v_blocking_reasons) r where r like '%cross_customer%' or r like '%conflict%') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'commercial_ambiguity_fails_closed');
    elsif v_confidence < 0.50 then
      v_outcome := 'FAILED_INTERPRETATION';
      v_decision_reasons := array_append(v_decision_reasons, 'low_confidence_interpretation');
    else
      v_outcome := 'CLARIFICATION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'missing_or_unresolved_facts_require_clarification');
    end if;
  end if;

  -- 7. Persist Autonomy Decision in whatsapp_order_autonomy_decisions (IMMUTABLE PATTERN)
  insert into public.whatsapp_order_autonomy_decisions(
    potential_order_id, case_id, packet_id, interpretation_id,
    autonomy_outcome, decision_reasons, blocking_reasons,
    governed_facts, readiness_snapshot, knowledge_snapshot_id,
    knowledge_snapshot_schema_version, resolver_rule_version
  ) values (
    v_po.id, v_case.id, p_packet_id, p_interpretation_id,
    v_outcome, v_decision_reasons, v_blocking_reasons,
    v_governed_facts, v_readiness, v_ai.knowledge_snapshot_id,
    v_ai.knowledge_snapshot_schema_version, 'core-a-autonomy/v1'
  )
  on conflict (packet_id, interpretation_id) do nothing
  returning * into v_decision;

  if v_decision.id is null then
    select * into v_decision
    from public.whatsapp_order_autonomy_decisions
    where packet_id = p_packet_id and interpretation_id = p_interpretation_id;
  end if;

  -- 8. Apply state transitions to Case and Potential Order
  if v_case.id is not null then
    if v_outcome = 'AUTO_ELIGIBLE' then
      update public.whatsapp_communication_cases
      set status = 'READY_FOR_DRAFT',
          next_action = 'CREATE_SALES_ORDER_DRAFT',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'CLARIFICATION_REQUIRED' then
      update public.whatsapp_communication_cases
      set status = 'AWAITING_CUSTOMER',
          next_action = 'AWAIT_CUSTOMER_CLARIFICATION',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'POLICY_APPROVAL_REQUIRED' then
      update public.whatsapp_communication_cases
      set status = case when v_customer_rec.resolution_status = 'RESOLVED' and status = 'NEEDS_IDENTITY' then 'OPEN' else status end,
          next_action = 'POLICY_APPROVAL_REQUIRED',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'HUMAN_EXCEPTION_REQUIRED' then
      update public.whatsapp_communication_cases
      set next_action = 'HUMAN_EXCEPTION_TRIAGE',
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'FAILED_INTERPRETATION' then
      update public.whatsapp_communication_cases
      set next_action = 'HUMAN_INTERPRETATION',
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    end if;

    v_event_key := 'autonomy-decision:' || p_interpretation_id::text;
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_id, actor_type, correlation_key,
      resulting_state, metadata
    ) values (
      v_case.id, 'AUTONOMY_EVALUATED', null, 'SYSTEM', v_event_key,
      jsonb_build_object(
        'autonomy_outcome', v_outcome,
        'case_status', v_case.status,
        'case_type', v_case.case_type,
        'human_decision_required', (v_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED'))
      ),
      jsonb_build_object(
        'decision_id', v_decision.id,
        'decision_reasons', to_jsonb(v_decision_reasons),
        'blocking_reasons', to_jsonb(v_blocking_reasons),
        'governed_facts', v_governed_facts,
        'readiness', v_readiness
      )
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  if v_po.id is not null then
    perform set_config('app.wa1_governed_mutation', 'on', true);
    if v_outcome = 'AUTO_ELIGIBLE' then
      update public.whatsapp_potential_orders
      set next_action = 'AUTO_CONVERT_DRAFT',
          updated_at = statement_timestamp()
      where id = v_po.id;
    elsif v_outcome = 'CLARIFICATION_REQUIRED' then
      update public.whatsapp_potential_orders
      set state = 'AWAITING_CLARIFICATION',
          next_action = 'AWAIT_CUSTOMER_CLARIFICATION',
          updated_at = statement_timestamp()
      where id = v_po.id;
    elsif v_outcome = 'FAILED_INTERPRETATION' then
      update public.whatsapp_potential_orders
      set state = 'FAILED_INTERPRETATION',
          queue = 'WA_FAILED_INTERPRETATION',
          next_action = 'HUMAN_INTERPRETATION',
          updated_at = statement_timestamp()
      where id = v_po.id;
    end if;
    perform set_config('app.wa1_governed_mutation', 'off', true);
  end if;

  return jsonb_build_object(
    'decision_id', v_decision.id,
    'autonomy_outcome', v_outcome,
    'case_id', v_case.id,
    'potential_order_id', v_po.id,
    'packet_id', p_packet_id,
    'interpretation_id', p_interpretation_id,
    'decision_reasons', to_jsonb(v_decision_reasons),
    'blocking_reasons', to_jsonb(v_blocking_reasons),
    'governed_facts', v_governed_facts,
    'readiness', v_readiness,
    'human_decision_required', (v_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED')),
    'idempotent_replay', false
  );
exception when others then
  perform set_config('app.wa1_governed_mutation', 'off', true);
  perform set_config('app.wa3_governed_mutation', 'off', true);
  raise;
end;
$$;



commit;
