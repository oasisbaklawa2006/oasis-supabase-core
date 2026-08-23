-- CORE-A: WhatsApp Autonomous Order Validation, Governed Field Materialisation,
-- and Autonomy Decision Engine.
-- Reconciles AI interpretation -> deterministic Core validation -> governed field materialisation -> autonomy decision.
-- Clear deterministic orders no longer require routine human ACCEPT/MODIFY/REJECT review.

begin;

-- 1. Governed Autonomy Decisions Ledger
create table if not exists public.whatsapp_order_autonomy_decisions (
  id uuid primary key default gen_random_uuid(),
  potential_order_id uuid references public.whatsapp_potential_orders(id) on delete restrict,
  case_id uuid references public.whatsapp_communication_cases(id) on delete restrict,
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  interpretation_id uuid not null references public.whatsapp_packet_ai_interpretations(id) on delete restrict,
  autonomy_outcome text not null check (autonomy_outcome in (
    'AUTO_ELIGIBLE',
    'CLARIFICATION_REQUIRED',
    'POLICY_APPROVAL_REQUIRED',
    'HUMAN_EXCEPTION_REQUIRED',
    'FAILED_INTERPRETATION'
  )),
  decision_reasons text[] not null default '{}'::text[],
  blocking_reasons text[] not null default '{}'::text[],
  governed_facts jsonb not null default '{}'::jsonb,
  readiness_snapshot jsonb not null default '{}'::jsonb,
  knowledge_snapshot_id uuid references public.whatsapp_intelligence_knowledge_snapshots(id) on delete restrict,
  knowledge_snapshot_schema_version text,
  resolver_rule_version text not null default 'core-a-autonomy/v1',
  evaluated_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_order_autonomy_decisions_unique unique (packet_id, interpretation_id)
);

create index if not exists whatsapp_order_autonomy_decisions_outcome_idx
  on public.whatsapp_order_autonomy_decisions(autonomy_outcome, evaluated_at desc);

create index if not exists whatsapp_order_autonomy_decisions_po_idx
  on public.whatsapp_order_autonomy_decisions(potential_order_id);

create index if not exists whatsapp_order_autonomy_decisions_case_idx
  on public.whatsapp_order_autonomy_decisions(case_id);

alter table public.whatsapp_order_autonomy_decisions enable row level security;
revoke all on table public.whatsapp_order_autonomy_decisions from public, anon, authenticated;
grant select, insert on table public.whatsapp_order_autonomy_decisions to service_role;
revoke update, delete on table public.whatsapp_order_autonomy_decisions from service_role;
grant select on table public.whatsapp_order_autonomy_decisions to authenticated;

create or replace function public.whatsapp_guard_autonomy_decision_immutable()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  raise exception 'whatsapp_order_autonomy_decisions is append-only' using errcode = '55000';
end;
$$;

drop trigger if exists whatsapp_order_autonomy_decisions_immutable on public.whatsapp_order_autonomy_decisions;
create trigger whatsapp_order_autonomy_decisions_immutable
  before update or delete on public.whatsapp_order_autonomy_decisions
  for each row execute function public.whatsapp_guard_autonomy_decision_immutable();

drop policy if exists whatsapp_order_autonomy_decisions_reader on public.whatsapp_order_autonomy_decisions;
create policy whatsapp_order_autonomy_decisions_reader
  on public.whatsapp_order_autonomy_decisions
  for select to authenticated
  using (public.has_whatsapp_permission('wa.intake.read'));

comment on table public.whatsapp_order_autonomy_decisions is
  'CORE-A governed autonomy decisions and provenance ledger. Records the single canonical autonomy outcome and verified commercial facts.';

-- 2. Extended Source Authorization Helper for Potential Orders
create or replace function public.whatsapp_potential_order_source_message_is_authorized(
  p_potential_order_id uuid,
  p_source_message_id uuid
) returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists(
    select 1 from public.whatsapp_potential_orders po
    where po.id = p_potential_order_id
      and (
        po.source_message_id = p_source_message_id
        or exists (
          select 1 from jsonb_array_elements(po.source_evidence) e
          where e->>'message_id' = p_source_message_id::text
             or e->>'inbound_message_id' = p_source_message_id::text
        )
        or exists (
          select 1 from public.whatsapp_potential_order_evidence_lineage l
          where l.potential_order_id = po.id
            and l.source_inbound_message_id = p_source_message_id
        )
        or exists (
          select 1 from public.whatsapp_commercial_evidence ce
          where ce.potential_order_id = po.id
            and ce.source_message_id = p_source_message_id
        )
        or exists (
          select 1
          from public.whatsapp_messages wm
          join public.whatsapp_inbound_messages im on im.provider_message_id = wm.provider_message_id
          where im.id = p_source_message_id
            and wm.direction = 'inbound'
            and (
              wm.provider_message_id = po.provider_message_id
              or exists (
                select 1 from jsonb_array_elements(po.source_evidence) e
                where e->>'provider_message_id' = wm.provider_message_id
              )
              or exists (
                select 1 from public.whatsapp_communication_cases c
                where c.packet_id = wm.packet_id
                  and public.whatsapp_case_potential_order_id(c.id) = po.id
              )
            )
        )
      )
  );
$$;

revoke all on function public.whatsapp_potential_order_source_message_is_authorized(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_potential_order_source_message_is_authorized(uuid, uuid)
  to service_role;

-- 3. Governing UOM Normalizer Helper
create or replace function public.whatsapp_normalize_governed_uom(p_unit text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select case lower(btrim(coalesce(p_unit, '')))
    when 'box' then 'Box'
    when 'boxes' then 'Box'
    when 'carton' then 'Carton'
    when 'cartons' then 'Carton'
    when 'pack' then 'Pack'
    when 'packs' then 'Pack'
    when 'kg' then 'Kg'
    when 'kgs' then 'Kg'
    when 'piece' then 'Piece'
    when 'pieces' then 'Piece'
    when 'pcs' then 'Piece'
    when 'tray' then 'Tray'
    when 'trays' then 'Tray'
    when 'tin' then 'Tin'
    when 'tins' then 'Tin'
    else null
  end;
$$;

revoke all on function public.whatsapp_normalize_governed_uom(text) from public, anon;
grant execute on function public.whatsapp_normalize_governed_uom(text) to authenticated, service_role;

-- 4. Deterministic Customer Resolver
-- Rules: Explicit current candidate evidence outranks historical/sender association.
-- Oasis employee submitting/relaying messages must never become customer based on their phone/authorization.
-- Only genuinely active/approved customer statuses ('active', 'approved') qualify. Never closed/pending/suspended.
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

  -- Priority 1: Explicit candidate GST match (CURRENT EVIDENCE OUTRANKS SENDER IDENTITY)
  if v_target_company_id is null and p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    if nullif(btrim(coalesce(p_candidate->>'gst_number', '')), '') is not null then
      v_has_explicit_candidate := true;
      v_candidate_gst := upper(btrim(regexp_replace(p_candidate->>'gst_number', '[^a-zA-Z0-9]', '', 'g')));

      if length(v_candidate_gst) >= 15 then
        select coalesce(array_agg(distinct c.id), '{}'::uuid[])
        into v_gst_company_ids
        from public.companies c
        where upper(regexp_replace(coalesce(c.gst_number, ''), '[^a-zA-Z0-9]', '', 'g')) = v_candidate_gst
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if cardinality(v_gst_company_ids) = 1 then
          v_target_company_id := v_gst_company_ids[1];
          v_method := 'EXACT_GST_MATCH';
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
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'MULTIPLE_NAME_MATCHES'::text, 0.5::numeric,
            jsonb_build_object('candidate_name', v_candidate_name, 'matched_company_ids', to_jsonb(v_name_company_ids));
          return;
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
  if v_target_company_id is null then
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
  if v_target_company_id is null and length(v_phone) >= 10 then
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_phone_company_ids
    from public.companies c
    where lower(coalesce(c.status, '')) in ('active', 'approved')
      and (
        c.phone = v_phone
        or lower(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g')) = v_phone
        or exists (
          select 1 from public.delivery_addresses da
          where da.company_id = c.id
            and (
              da.contact_phone = v_phone
              or lower(regexp_replace(coalesce(da.contact_phone, ''), '\D', '', 'g')) = v_phone
            )
        )
        or exists (
          select 1 from public.b2b_applications ba
          where ba.status = 'approved'
            and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g')) = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
            and (
              ba.contact_phone = v_phone
              or ba.mobile_number = v_phone
              or lower(regexp_replace(coalesce(ba.contact_phone, ''), '\D', '', 'g')) = v_phone
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

revoke all on function public.whatsapp_resolve_governed_customer(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.whatsapp_resolve_governed_customer(uuid, jsonb)
  to service_role;

-- 4. Deterministic Branch Resolver
-- Rules: Explicit unique governed branch, or an already-existing deterministic exactly-one rule only.
create or replace function public.whatsapp_resolve_governed_branch(
  p_company_id uuid,
  p_candidate jsonb default '{}'::jsonb
)
returns table (
  delivery_address_id uuid,
  label text,
  street_address text,
  city text,
  state text,
  pincode text,
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
  v_candidate_id uuid;
  v_candidate_label text;
  v_candidate_pincode text;
  v_candidate_city text;
  v_matches uuid[];
  v_total_count integer;
  v_addr public.delivery_addresses%rowtype;
begin
  if p_company_id is null then
    return query select
      null::uuid, null::text, null::text, null::text, null::text, null::text,
      'UNRESOLVED'::text, 'CUSTOMER_REQUIRED'::text, 0.0::numeric,
      jsonb_build_object('error', 'customer company required for branch resolution');
    return;
  end if;

  -- Priority 1: Explicit delivery_address_id if valid for this company
  if p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    if nullif(btrim(coalesce(p_candidate->>'delivery_address_id', '')), '') is not null then
      begin
        v_candidate_id := (p_candidate->>'delivery_address_id')::uuid;
      exception when others then
        v_candidate_id := null;
      end;

      if v_candidate_id is not null then
        select * into v_addr
        from public.delivery_addresses da
        where da.id = v_candidate_id and da.company_id = p_company_id;

        if found then
          return query select
            v_addr.id, v_addr.label, v_addr.street_address, v_addr.city, v_addr.state, v_addr.pincode,
            'RESOLVED'::text, 'EXACT_DELIVERY_ADDRESS_ID'::text, 1.0::numeric,
            to_jsonb(v_addr);
          return;
        else
          return query select
            null::uuid, null::text, null::text, null::text, null::text, null::text,
            'UNRESOLVED'::text, 'EXPLICIT_ADDRESS_ID_NOT_FOUND_FOR_COMPANY'::text, 0.0::numeric,
            jsonb_build_object('delivery_address_id', v_candidate_id, 'company_id', p_company_id);
          return;
        end if;
      else
        return query select
          null::uuid, null::text, null::text, null::text, null::text, null::text,
          'UNRESOLVED'::text, 'INVALID_DELIVERY_ADDRESS_ID_FORMAT'::text, 0.0::numeric,
          jsonb_build_object('candidate_address_id', p_candidate->>'delivery_address_id');
        return;
      end if;
    end if;
  end if;

  -- Priority 2: Explicit label / branch_name match
  if p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    v_candidate_label := lower(btrim(coalesce(p_candidate->>'branch_name', p_candidate->>'label', p_candidate->>'branch', '')));
    if length(v_candidate_label) >= 2 then
      select coalesce(array_agg(da.id), '{}'::uuid[])
      into v_matches
      from public.delivery_addresses da
      where da.company_id = p_company_id
        and lower(btrim(da.label)) = v_candidate_label;

      if cardinality(v_matches) = 1 then
        select * into v_addr from public.delivery_addresses da where da.id = v_matches[1];
        return query select
          v_addr.id, v_addr.label, v_addr.street_address, v_addr.city, v_addr.state, v_addr.pincode,
          'RESOLVED'::text, 'EXACT_BRANCH_LABEL_MATCH'::text, 1.0::numeric,
          to_jsonb(v_addr);
        return;
      elsif cardinality(v_matches) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, null::text, null::text,
          'AMBIGUOUS'::text, 'MULTIPLE_BRANCH_LABEL_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('candidate_label', v_candidate_label, 'matched_ids', to_jsonb(v_matches));
        return;
      end if;
    end if;

    -- Priority 3: Explicit pincode match
    v_candidate_pincode := btrim(regexp_replace(coalesce(p_candidate->>'pincode', ''), '\D', '', 'g'));
    if length(v_candidate_pincode) = 6 then
      select coalesce(array_agg(da.id), '{}'::uuid[])
      into v_matches
      from public.delivery_addresses da
      where da.company_id = p_company_id
        and btrim(regexp_replace(coalesce(da.pincode, ''), '\D', '', 'g')) = v_candidate_pincode;

      if cardinality(v_matches) = 1 then
        select * into v_addr from public.delivery_addresses da where da.id = v_matches[1];
        return query select
          v_addr.id, v_addr.label, v_addr.street_address, v_addr.city, v_addr.state, v_addr.pincode,
          'RESOLVED'::text, 'EXACT_PINCODE_MATCH'::text, 1.0::numeric,
          to_jsonb(v_addr);
        return;
      elsif cardinality(v_matches) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, null::text, null::text,
          'AMBIGUOUS'::text, 'MULTIPLE_PINCODE_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('candidate_pincode', v_candidate_pincode, 'matched_ids', to_jsonb(v_matches));
        return;
      end if;
    end if;

    -- Priority 4: Explicit city match
    v_candidate_city := lower(btrim(coalesce(p_candidate->>'city', '')));
    if length(v_candidate_city) >= 3 then
      select coalesce(array_agg(da.id), '{}'::uuid[])
      into v_matches
      from public.delivery_addresses da
      where da.company_id = p_company_id
        and lower(btrim(da.city)) = v_candidate_city;

      if cardinality(v_matches) = 1 then
        select * into v_addr from public.delivery_addresses da where da.id = v_matches[1];
        return query select
          v_addr.id, v_addr.label, v_addr.street_address, v_addr.city, v_addr.state, v_addr.pincode,
          'RESOLVED'::text, 'EXACT_CITY_MATCH'::text, 1.0::numeric,
          to_jsonb(v_addr);
        return;
      elsif cardinality(v_matches) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, null::text, null::text,
          'AMBIGUOUS'::text, 'MULTIPLE_CITY_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('candidate_city', v_candidate_city, 'matched_ids', to_jsonb(v_matches));
        return;
      end if;
    end if;
  end if;

  -- Priority 5: Deterministic exactly-one rule
  select count(*), (array_agg(da.id order by da.id))[1]
  into v_total_count, v_candidate_id
  from public.delivery_addresses da
  where da.company_id = p_company_id;

  if v_total_count = 1 and v_candidate_id is not null then
    select * into v_addr from public.delivery_addresses da where da.id = v_candidate_id;
    return query select
      v_addr.id, v_addr.label, v_addr.street_address, v_addr.city, v_addr.state, v_addr.pincode,
      'RESOLVED'::text, 'DETERMINISTIC_EXACTLY_ONE'::text, 1.0::numeric,
      to_jsonb(v_addr);
    return;
  elsif v_total_count > 1 then
    return query select
      null::uuid, null::text, null::text, null::text, null::text, null::text,
      'AMBIGUOUS'::text, 'MULTIPLE_BRANCHES_REQUIRE_SPECIFICATION'::text, 0.5::numeric,
      jsonb_build_object('available_branch_count', v_total_count);
    return;
  end if;

  return query select
    null::uuid, null::text, null::text, null::text, null::text, null::text,
    'UNRESOLVED'::text, 'NO_DELIVERY_ADDRESS_ON_FILE'::text, 0.0::numeric,
    jsonb_build_object('company_id', p_company_id);
end;
$$;

revoke all on function public.whatsapp_resolve_governed_branch(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.whatsapp_resolve_governed_branch(uuid, jsonb)
  to service_role;

-- 5. Deterministic Product Line Resolver
-- Rules: Exact SKU, unique canonical product or unique approved governed alias.
-- Quantity: Explicit current evidence only. NEVER default to 1. No executable quantity=1 fallback.
-- Reuses canonical B2B authority (customer_resolve_buyer_product_authority_v1, customer_validate_order_quantity_v1).
create or replace function public.whatsapp_resolve_governed_product_line(
  p_line jsonb,
  p_knowledge_snapshot_id uuid default null,
  p_company_id uuid default null,
  p_packet_id uuid default null
)
returns table (
  product_id uuid,
  sku text,
  product_name text,
  quantity numeric,
  uom text,
  pack_size text,
  moq numeric,
  moq_satisfied boolean,
  resolution_status text,
  match_method text,
  confidence numeric,
  unresolved_reasons text[],
  details jsonb
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_prod_id uuid;
  v_sku text;
  v_name text;
  v_raw_unit text;
  v_norm_unit text;
  v_raw_qty text;
  v_qty numeric;
  v_product public.products%rowtype;
  v_matches uuid[];
  v_reasons text[] := '{}'::text[];
  v_method text;
  v_moq numeric;
  v_moq_ok boolean := true;
  v_knowledge jsonb;
  v_know_sku text;
  v_status text;
  v_evidence_ids jsonb;
  v_valid_evidence_count integer := 0;
  v_authority record;
  v_has_b2b_authority boolean := false;
  v_b2b_valid_qty boolean;
begin
  if p_line is null or jsonb_typeof(p_line) <> 'object' then
    return query select
      null::uuid, null::text, null::text, null::numeric, null::text, null::text,
      null::numeric, false, 'UNRESOLVED'::text, 'INVALID_LINE_PAYLOAD'::text,
      0.0::numeric, array['invalid_line_payload']::text[], '{}'::jsonb;
    return;
  end if;

  -- 1. Quantity check: must be explicit current evidence, not merely AI numeric.
  v_status := lower(btrim(coalesce(p_line->>'status', '')));
  v_evidence_ids := case
    when jsonb_typeof(p_line->'evidence_ids') = 'array' then p_line->'evidence_ids'
    else '[]'::jsonb
  end;

  -- Validate referenced evidence belongs to this packet if packet_id provided
  if p_packet_id is not null and jsonb_array_length(v_evidence_ids) > 0 then
    select count(*) into v_valid_evidence_count
    from public.whatsapp_messages wm
    where wm.packet_id = p_packet_id
      and wm.direction = 'inbound'
      and wm.provider_message_id in (select jsonb_array_elements_text(v_evidence_ids));
  elsif p_packet_id is null and jsonb_array_length(v_evidence_ids) > 0 then
    v_valid_evidence_count := jsonb_array_length(v_evidence_ids);
  else
    v_valid_evidence_count := 0;
  end if;

  if jsonb_typeof(p_line->'quantity') = 'number' then
    v_qty := (p_line->>'quantity')::numeric;
    if v_qty <= 0 then
      v_qty := null;
      v_reasons := array_append(v_reasons, 'quantity_must_be_positive');
    end if;
  elsif jsonb_typeof(p_line->'quantity') = 'string' then
    v_raw_qty := btrim(p_line->>'quantity');
    begin
      v_qty := v_raw_qty::numeric;
      if v_qty <= 0 then
        v_qty := null;
        v_reasons := array_append(v_reasons, 'quantity_must_be_positive');
      end if;
    exception when others then
      v_qty := null;
      v_reasons := array_append(v_reasons, 'quantity_unparseable');
    end;
  else
    v_qty := null;
    v_reasons := array_append(v_reasons, 'missing_quantity');
  end if;

  -- DEFECT 2 FIX: AI-interpreted / inferred / default quantity without explicit fact or valid evidence must remain UNRESOLVED
  if v_qty is not null then
    if v_status in ('interpreted', 'inferred', 'suggested', 'default', 'unclear', 'unknown')
       or jsonb_array_length(v_evidence_ids) = 0
       or (p_packet_id is not null and v_valid_evidence_count = 0) then
      v_qty := null;
      v_reasons := array_append(v_reasons, 'quantity_not_evidence_proven');
    end if;
  end if;

  -- 2. Product resolution
  -- Step A: Try explicit product_id
  begin
    v_prod_id := nullif(p_line->>'product_id', '')::uuid;
  exception when others then
    v_prod_id := null;
  end;

  if v_prod_id is not null then
    select * into v_product from public.products p where p.id = v_prod_id and p.is_active = true;
    if found then
      v_method := 'EXACT_PRODUCT_ID';
    end if;
  end if;

  -- Step B: Try exact SKU match
  if v_product.id is null then
    v_sku := nullif(btrim(coalesce(p_line->>'sku', '')), '');
    if v_sku is not null then
      select coalesce(array_agg(p.id), '{}'::uuid[])
      into v_matches
      from public.products p
      where lower(btrim(p.sku)) = lower(v_sku)
        and p.is_active = true;

      if cardinality(v_matches) = 1 then
        select * into v_product from public.products p where p.id = v_matches[1];
        v_method := 'EXACT_SKU_MATCH';
      elsif cardinality(v_matches) > 1 then
        v_reasons := array_append(v_reasons, 'ambiguous_sku_multi_match');
      end if;
    end if;
  end if;

  -- Step C: Try exact product name match
  if v_product.id is null and not ('ambiguous_sku_multi_match' = any(v_reasons)) then
    v_name := nullif(btrim(coalesce(p_line->>'product_name', p_line->>'name', '')), '');
    if v_name is not null then
      select coalesce(array_agg(p.id), '{}'::uuid[])
      into v_matches
      from public.products p
      where lower(btrim(p.name)) = lower(v_name)
        and p.is_active = true;

      if cardinality(v_matches) = 1 then
        select * into v_product from public.products p where p.id = v_matches[1];
        v_method := 'EXACT_NAME_MATCH';
      elsif cardinality(v_matches) > 1 then
        v_reasons := array_append(v_reasons, 'ambiguous_product_name_multi_match');
      end if;
    end if;
  end if;

  -- Step D: Try approved governed alias match in public.product_aliases
  if v_product.id is null and v_name is not null and not ('ambiguous_product_name_multi_match' = any(v_reasons)) then
    select coalesce(array_agg(distinct pa.product_id), '{}'::uuid[])
    into v_matches
    from public.product_aliases pa
    join public.products p on p.id = pa.product_id
    where lower(btrim(pa.alias_text)) = lower(v_name)
      and p.is_active = true;

    if cardinality(v_matches) = 1 then
      select * into v_product from public.products p where p.id = v_matches[1];
      v_method := 'APPROVED_GOVERNED_ALIAS';
    elsif cardinality(v_matches) > 1 then
      v_reasons := array_append(v_reasons, 'ambiguous_alias_multi_match');
    end if;
  end if;

  -- Step E: Try active intelligence knowledge snapshot terminology
  if v_product.id is null and v_name is not null and p_knowledge_snapshot_id is not null
     and not ('ambiguous_alias_multi_match' = any(v_reasons)) then
    select knowledge into v_knowledge
    from public.whatsapp_intelligence_knowledge_snapshots
    where id = p_knowledge_snapshot_id;

    if v_knowledge is not null then
      v_know_sku := nullif(btrim(coalesce(
        v_knowledge #>> array['terminology', v_name],
        v_knowledge #>> array['aliases', v_name],
        v_knowledge #>> array['sku_map', v_name],
        ''
      )), '');

      if v_know_sku is not null then
        select coalesce(array_agg(p.id), '{}'::uuid[])
        into v_matches
        from public.products p
        where (lower(btrim(p.sku)) = lower(v_know_sku) or lower(btrim(p.name)) = lower(v_know_sku))
          and p.is_active = true;

        if cardinality(v_matches) = 1 then
          select * into v_product from public.products p where p.id = v_matches[1];
          v_method := 'KNOWLEDGE_SNAPSHOT_TERMINOLOGY';
        elsif cardinality(v_matches) > 1 then
          v_reasons := array_append(v_reasons, 'ambiguous_knowledge_snapshot_multi_match');
        end if;
      end if;
    end if;
  end if;

  if v_product.id is null then
    if cardinality(v_reasons) = 0 or (cardinality(v_reasons) = 1 and v_reasons[1] in ('missing_quantity', 'quantity_not_evidence_proven')) then
      v_reasons := array_append(v_reasons, 'unresolved_product');
    end if;
  end if;

  -- 3. Canonical B2B Authority & UOM / MOQ / Increment / Carton Validation
  v_raw_unit := nullif(lower(btrim(coalesce(p_line->>'unit', p_line->>'uom', p_line->>'packaging', ''))), '');

  if v_product.id is not null then
    -- Check Canonical B2B Authority if company_id is present
    if p_company_id is not null then
      select * into v_authority
      from public.customer_resolve_buyer_product_authority_v1(p_company_id, v_product.id);

      if v_authority.product_id is not null then
        v_has_b2b_authority := true;
        if not coalesce(v_authority.is_available, false) then
          v_reasons := array_append(v_reasons, 'product_not_available_for_buyer');
        end if;

        -- Validate UOM against canonical B2B pricing UOM and master data
        if v_raw_unit is null then
          v_reasons := array_append(v_reasons, 'unresolved_unit');
          v_norm_unit := null;
        else
          v_norm_unit := case v_raw_unit
            when 'box' then 'Box'
            when 'boxes' then 'Box'
            when 'carton' then 'Carton'
            when 'cartons' then 'Carton'
            when 'pack' then 'Pack'
            when 'packs' then 'Pack'
            when 'kg' then 'Kg'
            when 'kgs' then 'Kg'
            when 'piece' then 'Piece'
            when 'pieces' then 'Piece'
            when 'pcs' then 'Piece'
            when 'tray' then 'Tray'
            when 'trays' then 'Tray'
            when 'tin' then 'Tin'
            when 'tins' then 'Tin'
            else null
          end;

          if v_norm_unit is null then
            if lower(btrim(coalesce(v_authority.uom, ''))) = v_raw_unit then
              v_norm_unit := coalesce(v_authority.uom, 'Pack');
            elsif lower(btrim(coalesce(v_product.uom, ''))) = v_raw_unit then
              v_norm_unit := coalesce(v_product.uom, 'Pack');
            else
              v_reasons := array_append(v_reasons, 'invalid_or_ambiguous_uom');
            end if;
          end if;

          -- Carton check: "Carton" as text alone does not authorize carton semantics without min_carton_qty or packs_per_carton
          if v_norm_unit = 'Carton' and coalesce(v_authority.min_carton_qty, v_product.packs_per_carton, v_product.packs_per_master_carton) is null then
            v_reasons := array_append(v_reasons, 'carton_without_governed_carton_authority');
          end if;
        end if;

        -- Canonical MOQ & Increment Validation
        v_moq := v_authority.minimum_order_quantity;
        if v_qty is not null then
          v_b2b_valid_qty := public.customer_validate_order_quantity_v1(
            v_qty,
            v_authority.minimum_order_quantity,
            v_authority.order_increment,
            v_authority.min_carton_qty
          );

          if not v_b2b_valid_qty then
            v_moq_ok := false;
            v_reasons := array_append(v_reasons, 'violates_canonical_b2b_moq_or_increment_or_carton');
          end if;
        end if;
      else
        -- Company exists but has no approved B2B pricing / commercial authority for this product
        v_reasons := array_append(v_reasons, 'missing_approved_b2b_product_authority');
      end if;
    end if;

    -- Fallback master product validation if p_company_id was null (e.g. standalone test)
    if not v_has_b2b_authority then
      if v_raw_unit is null then
        v_reasons := array_append(v_reasons, 'unresolved_unit');
        v_norm_unit := null;
      else
        v_norm_unit := case v_raw_unit
          when 'box' then 'Box'
          when 'boxes' then 'Box'
          when 'carton' then 'Carton'
          when 'cartons' then 'Carton'
          when 'pack' then 'Pack'
          when 'packs' then 'Pack'
          when 'kg' then 'Kg'
          when 'kgs' then 'Kg'
          when 'piece' then 'Piece'
          when 'pieces' then 'Piece'
          when 'pcs' then 'Piece'
          when 'tray' then 'Tray'
          when 'trays' then 'Tray'
          when 'tin' then 'Tin'
          when 'tins' then 'Tin'
          else null
        end;

        if v_norm_unit is null then
          if lower(btrim(coalesce(v_product.uom, ''))) = v_raw_unit then
            v_norm_unit := coalesce(v_product.uom, 'Pack');
          else
            v_reasons := array_append(v_reasons, 'invalid_or_ambiguous_uom');
          end if;
        end if;

        if v_norm_unit = 'Carton' and coalesce(v_product.packs_per_carton, v_product.packs_per_master_carton) is null then
          v_reasons := array_append(v_reasons, 'carton_without_governed_carton_authority');
        end if;
      end if;

      v_moq := coalesce(v_product.moq_packs, v_product.moq, 1);
      if v_qty is not null and v_qty < v_moq then
        v_moq_ok := false;
        v_reasons := array_append(v_reasons, 'below_moq_carton_constraint');
      end if;
    end if;
  end if;

  if v_product.id is not null and v_qty is not null and v_norm_unit is not null and cardinality(v_reasons) = 0 then
    return query select
      v_product.id,
      v_product.sku,
      v_product.name,
      v_qty,
      v_norm_unit,
      v_product.pack_size,
      v_moq,
      v_moq_ok,
      'RESOLVED'::text,
      v_method,
      1.0::numeric,
      '{}'::text[],
      jsonb_build_object(
        'product_id', v_product.id,
        'sku', v_product.sku,
        'name', v_product.name,
        'quantity', v_qty,
        'uom', v_norm_unit,
        'pack_size', v_product.pack_size,
        'moq', v_moq,
        'moq_satisfied', v_moq_ok,
        'match_method', v_method,
        'has_b2b_authority', v_has_b2b_authority
      );
    return;
  elsif exists (select 1 from unnest(v_reasons) r where r like '%ambiguous%') then
    return query select
      v_product.id,
      v_product.sku,
      v_product.name,
      v_qty,
      v_norm_unit,
      v_product.pack_size,
      v_moq,
      v_moq_ok,
      'AMBIGUOUS'::text,
      coalesce(v_method, 'FAILED_PRODUCT_RESOLUTION'),
      0.5::numeric,
      v_reasons,
      jsonb_build_object('unresolved_reasons', to_jsonb(v_reasons), 'raw_line', p_line);
    return;
  else
    return query select
      v_product.id,
      v_product.sku,
      v_product.name,
      v_qty,
      v_norm_unit,
      v_product.pack_size,
      v_moq,
      v_moq_ok,
      'UNRESOLVED'::text,
      coalesce(v_method, 'FAILED_PRODUCT_RESOLUTION'),
      0.0::numeric,
      v_reasons,
      jsonb_build_object('unresolved_reasons', to_jsonb(v_reasons), 'raw_line', p_line);
    return;
  end if;
end;
$$;

revoke all on function public.whatsapp_resolve_governed_product_line(jsonb, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_resolve_governed_product_line(jsonb, uuid, uuid, uuid)
  to service_role;

-- 6. Upgraded record_whatsapp_order_field_evidence with Correction Precedence
-- Rules: Later explicit correction supersedes prior conflicting evidence. Do not rewrite immutable evidence.
create or replace function public.record_whatsapp_order_field_evidence(
 p_potential_order_id uuid,p_field_key text,p_source_message_id uuid,p_evidence_key text,p_candidate_value jsonb,
 p_extraction_state text,p_confidence numeric default null,p_source_excerpt text default null,p_metadata jsonb default '{}',p_is_required boolean default true
) returns public.whatsapp_order_field_resolutions
language plpgsql security definer set search_path = pg_catalog, public, auth as $$
declare
  v_po public.whatsapp_potential_orders%rowtype;
  v_evidence public.whatsapp_order_field_evidence%rowtype;
  v_existing public.whatsapp_order_field_resolutions%rowtype;
  v_result public.whatsapp_order_field_resolutions%rowtype;
  v_state text;
  v_question text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' and (auth.uid() is null or not public.has_whatsapp_permission('wa.intake.triage')) then
   raise exception 'WA3_TRIAGE_REQUIRED' using errcode='P0001';
 end if;
 if p_field_key not in('client_identity','product','quantity','unit_packaging','delivery_address','payment_terms','moq_carton') then
   raise exception 'WA3_INVALID_FIELD';
 end if;
 if nullif(btrim(p_evidence_key),'') is null then
   raise exception 'WA3_EVIDENCE_KEY_REQUIRED';
 end if;

 select * into v_po from public.whatsapp_potential_orders where id=p_potential_order_id for update;
 if not found or v_po.disposition<>'ACTIVE_PENDING' then
   raise exception 'WA3_ACTIVE_POTENTIAL_ORDER_REQUIRED';
 end if;
 if not public.whatsapp_potential_order_source_message_is_authorized(p_potential_order_id,p_source_message_id) then
   raise exception 'WA3_SOURCE_NOT_LINKED';
 end if;

 insert into public.whatsapp_order_field_evidence(
   potential_order_id,field_key,source_message_id,evidence_key,candidate_value,
   extraction_state,confidence,source_excerpt,metadata,recorded_by
 ) values (
   p_potential_order_id,p_field_key,p_source_message_id,btrim(p_evidence_key),p_candidate_value,
   p_extraction_state,p_confidence,p_source_excerpt,coalesce(p_metadata,'{}'),auth.uid()
 )
 on conflict(potential_order_id,field_key,evidence_key) do nothing returning * into v_evidence;

 if not found then
   select * into v_evidence from public.whatsapp_order_field_evidence
   where potential_order_id=p_potential_order_id and field_key=p_field_key and evidence_key=btrim(p_evidence_key);
 end if;

 select * into v_existing from public.whatsapp_order_field_resolutions
 where potential_order_id=p_potential_order_id and field_key=p_field_key for update;

 -- Deterministic resolution state with explicit correction precedence
 v_state:=case
  when v_evidence.extraction_state='not_applicable' and not p_is_required then 'not_applicable'
  when v_evidence.extraction_state='operator_confirmation' and auth.uid() is not null and v_evidence.candidate_value is not null then 'operator_confirmed'
  when v_evidence.extraction_state='historical_reference' then 'awaiting_clarification'
  when v_evidence.extraction_state in('ambiguous','low_confidence') then 'ambiguous'
  when v_evidence.extraction_state in('ai_failure','unresolved') or v_evidence.candidate_value is null then 'unresolved'
  when coalesce(v_evidence.confidence,1)<0.70 then 'ambiguous'
  when found and v_existing.resolved_value is not null and v_existing.resolved_value<>v_evidence.candidate_value and coalesce(v_evidence.metadata->>'governed_materialisation','')<>'true' then 'conflicting'
  else 'resolved' end;

 perform set_config('app.wa3_governed_mutation','on',true);
 insert into public.whatsapp_order_field_resolutions(
   potential_order_id,field_key,resolution_state,is_required,resolved_value,
   resolved_evidence_id,resolution_reason,resolved_by,resolved_at
 ) values (
   p_potential_order_id,p_field_key,v_state,p_is_required,
   case when v_state in('resolved','operator_confirmed') then v_evidence.candidate_value end,
   case when v_state in('resolved','operator_confirmed') then v_evidence.id end,
   case
     when v_state='not_applicable' then coalesce(v_evidence.metadata->>'reason','explicitly not applicable')
     else v_evidence.extraction_state
   end,
   case when v_state in('operator_confirmed','not_applicable') then auth.uid() end,
   case when v_state in('resolved','operator_confirmed') then statement_timestamp() end
 )
 on conflict(potential_order_id,field_key) do update set
   resolution_state=excluded.resolution_state,
   is_required=excluded.is_required,
   resolved_value=excluded.resolved_value,
   resolved_evidence_id=excluded.resolved_evidence_id,
   resolution_reason=excluded.resolution_reason,
   resolved_by=excluded.resolved_by,
   resolved_at=excluded.resolved_at,
   updated_at=statement_timestamp()
 returning * into v_result;

 -- If field is resolved or confirmed, answer open clarification tasks
 if v_state in ('resolved', 'operator_confirmed') then
   update public.whatsapp_order_clarification_tasks
   set status='ANSWERED',
       answer_evidence_id=v_evidence.id,
       answered_at=statement_timestamp(),
       answered_by=auth.uid()
   where potential_order_id=p_potential_order_id
     and field_key=p_field_key
     and status='OPEN';
 elsif v_state in('unresolved','ambiguous','conflicting','awaiting_clarification') then
  v_question:=public.wa3_clarification_question(p_field_key);
  insert into public.whatsapp_order_clarification_tasks(potential_order_id,field_key,idempotency_key,question,owner_id,created_by)
  values(p_potential_order_id,p_field_key,'field:'||p_field_key||':evidence:'||v_evidence.id,v_question,v_po.owner_id,auth.uid())
  on conflict do nothing;

  perform set_config('app.wa1_governed_mutation','on',true);
  update public.whatsapp_potential_orders
  set state='AWAITING_CLARIFICATION',
      next_action='CLARIFY_'||upper(p_field_key),
      next_action_due_at=least(next_action_due_at,statement_timestamp()+interval '30 minutes'),
      updated_at=statement_timestamp()
  where id=p_potential_order_id;

  insert into public.whatsapp_potential_order_audit_log(
    potential_order_id,action,from_state,to_state,actor_id,evidence
  ) values (
    p_potential_order_id,'FIELD_CLARIFICATION_REQUIRED',v_po.state,'AWAITING_CLARIFICATION',
    auth.uid(),jsonb_build_object('field_key',p_field_key,'evidence_id',v_evidence.id,'resolution_state',v_state)
  );
  perform set_config('app.wa1_governed_mutation','off',true);
 end if;

 perform set_config('app.wa3_governed_mutation','off',true);
 return v_result;
exception when others then
 perform set_config('app.wa3_governed_mutation','off',true);
 perform set_config('app.wa1_governed_mutation','off',true);
 raise;
end $$;

revoke all on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)
  from public, anon;
grant execute on function public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)
  to authenticated, service_role;

-- 7. CORE-A Autonomy Evaluation & Materialisation Engine
-- Validates: Customer, Branch, Product Lines (exact SKU, explicit quantity, governed UOM/pack, MOQ), Payment Terms.
-- Derives: AUTO_ELIGIBLE | CLARIFICATION_REQUIRED | POLICY_APPROVAL_REQUIRED | HUMAN_EXCEPTION_REQUIRED | FAILED_INTERPRETATION.
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
  v_blocking_reasons text[] := '{}'::text[];
  v_decision_reasons text[] := '{}'::text[];
  v_governed_facts jsonb := '{}'::jsonb;
  v_readiness jsonb;
  v_is_ready boolean := false;
  v_outcome text;
  v_confidence numeric;
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_event_key text;
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
      v_outcome := 'FAILED_INTERPRETATION';
      v_decision_reasons := array_append(v_decision_reasons, 'unclear_or_unsupported_intent');
      v_blocking_reasons := array_append(v_blocking_reasons, 'unclear_intent');
    end if;
  end if;

  -- 2. Customer Validation (Deterministic, fail-closed)
  select * into v_customer_rec
  from public.whatsapp_resolve_governed_customer(
    v_packet.contact_id,
    case when jsonb_typeof(v_conclusion->'customer') = 'object' then v_conclusion->'customer' else '{}'::jsonb end
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
      v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_branch');
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
      if not coalesce(v_line_rec.moq_satisfied, true)
         or 'below_moq_carton_constraint' = any(v_line_rec.unresolved_reasons)
         or 'violates_canonical_b2b_moq_or_increment_or_carton' = any(v_line_rec.unresolved_reasons) then
        v_any_below_moq := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'below_moq_line_' || v_line_idx::text);
      end if;

      if 'missing_quantity' = any(v_line_rec.unresolved_reasons) or 'quantity_not_evidence_proven' = any(v_line_rec.unresolved_reasons) then
        v_all_lines_resolved := false;
        v_any_missing_qty := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'missing_explicit_quantity_line_' || v_line_idx::text);
      end if;
      if exists (select 1 from unnest(v_line_rec.unresolved_reasons) r where r like '%ambiguous%') then
        v_all_lines_resolved := false;
        v_any_ambiguous_sku := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_product' = any(v_line_rec.unresolved_reasons) then
        v_all_lines_resolved := false;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_unit' = any(v_line_rec.unresolved_reasons) or 'invalid_or_ambiguous_uom' = any(v_line_rec.unresolved_reasons) then
        v_all_lines_resolved := false;
        v_any_ambiguous_uom := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_unit_line_' || v_line_idx::text);
      end if;
      if 'missing_approved_b2b_product_authority' = any(v_line_rec.unresolved_reasons) or 'product_not_available_for_buyer' = any(v_line_rec.unresolved_reasons) then
        v_all_lines_resolved := false;
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
    v_readiness := public.evaluate_whatsapp_order_readiness(v_po.id);
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
          and v_branch_status = 'RESOLVED'
          and v_all_lines_resolved
          and not v_any_missing_qty
          and not v_any_ambiguous_sku
          and not v_any_ambiguous_uom
          and cardinality(v_blocking_reasons) = 0 then
      v_outcome := 'AUTO_ELIGIBLE';
      v_decision_reasons := array_append(v_decision_reasons, 'all_commercial_facts_deterministically_resolved');
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

revoke all on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint)
  to service_role;

comment on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint) is
  'CORE-A canonical autonomy evaluator and governed field materialiser. Validates customer, branch, products, explicit quantities, and UOM against master data, deriving one of the 5 canonical autonomy outcomes.';

-- 8. Upgraded whatsapp_materialize_packet_ai_case with Autonomy Integration
create or replace function public.whatsapp_materialize_packet_ai_case(
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
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case_type text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_recommended_action text;
  v_primary_department text;
  v_contributors jsonb;
  v_reply_clearance text;
  v_draft_reply text;
  v_ambiguity_count integer := 0;
  v_event_key text;
  v_autonomy jsonb;
  v_autonomy_outcome text;
  v_human_decision_required boolean;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  select * into v_packet
  from public.whatsapp_message_packets
  where id = p_packet_id;

  if not found then
    raise exception 'WhatsApp packet not found';
  end if;

  select * into v_ai
  from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id
    and packet_id = p_packet_id;

  if not found then
    raise exception 'packet AI interpretation not found for packet';
  end if;

  select * into v_contact
  from public.whatsapp_contacts
  where id = v_packet.contact_id;

  if not found then
    raise exception 'WhatsApp packet contact not found';
  end if;

  v_conclusion := case
    when jsonb_typeof(v_ai.interpretation -> 'conclusion') = 'object'
      then v_ai.interpretation -> 'conclusion'
    else '{}'::jsonb
  end;

  v_intent := upper(coalesce(nullif(btrim(v_conclusion ->> 'intent'), ''), 'UNCLEAR'));
  v_case_type := case v_intent
    when 'NEW_ORDER' then 'ORDER'
    when 'ORDER' then 'ORDER'
    when 'AMENDMENT' then 'ORDER_CHANGE'
    when 'ORDER_CHANGE' then 'ORDER_CHANGE'
    when 'CANCELLATION' then 'CANCELLATION'
    when 'ENQUIRY' then 'ENQUIRY'
    when 'COMPLAINT' then 'COMPLAINT'
    when 'PAYMENT_ADVICE' then 'PAYMENT_ADVICE'
    when 'ACCOUNT_QUERY' then 'ACCOUNT_QUERY'
    when 'FINANCE' then 'ACCOUNT_QUERY'
    when 'DELIVERY_QUERY' then 'DISPATCH'
    when 'DISPATCH' then 'DISPATCH'
    when 'SPECIFICATION_QUERY' then 'SPECIFICATION'
    when 'SPECIFICATION' then 'SPECIFICATION'
    else 'UNCLASSIFIED'
  end;

  v_recommended_action := nullif(btrim(coalesce(v_conclusion ->> 'recommended_action', '')), '');
  v_primary_department := nullif(upper(btrim(coalesce(v_conclusion ->> 'primary_department', ''))), '');
  v_contributors := case
    when jsonb_typeof(v_conclusion -> 'contributor_departments') = 'array'
      then v_conclusion -> 'contributor_departments'
    else '[]'::jsonb
  end;
  v_reply_clearance := nullif(upper(btrim(coalesce(v_conclusion ->> 'reply_clearance', ''))), '');
  v_draft_reply := nullif(btrim(coalesce(v_conclusion ->> 'draft_reply', '')), '');
  v_ambiguity_count := case
    when jsonb_typeof(v_conclusion -> 'ambiguities') = 'array'
      then jsonb_array_length(v_conclusion -> 'ambiguities')
    else 0
  end;

  insert into public.whatsapp_communication_cases (
    packet_id,
    case_type,
    status,
    next_action,
    source_channel,
    rule_version
  ) values (
    p_packet_id,
    v_case_type,
    'NEEDS_IDENTITY',
    v_recommended_action,
    'WHATSAPP',
    'packet-ai-b2b-v1'
  )
  on conflict (packet_id) do update
  set case_type = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
          then excluded.case_type
        else public.whatsapp_communication_cases.case_type
      end,
      next_action = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
          then excluded.next_action
        else public.whatsapp_communication_cases.next_action
      end,
      rule_version = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
          then excluded.rule_version
        else public.whatsapp_communication_cases.rule_version
      end,
      updated_at = statement_timestamp()
  returning * into v_case;

  insert into public.whatsapp_case_identities (
    case_id,
    identity_role,
    party_type,
    party_id,
    display_label,
    phone_e164,
    resolution_status,
    confidence,
    evidence
  ) values (
    v_case.id,
    'SUBMITTING_SENDER',
    'CONTACT',
    v_contact.id,
    coalesce(nullif(v_contact.customer_name, ''), nullif(v_contact.company_name, ''), v_contact.phone_number),
    v_contact.phone_number,
    'SUGGESTED',
    1.0,
    jsonb_build_array(jsonb_build_object(
      'source', 'WHATSAPP_PACKET',
      'packet_id', p_packet_id,
      'contact_id', v_contact.id
    ))
  )
  on conflict (case_id, identity_role) do update
  set party_type = excluded.party_type,
      party_id = excluded.party_id,
      display_label = excluded.display_label,
      phone_e164 = excluded.phone_e164,
      confidence = excluded.confidence,
      evidence = excluded.evidence
  where public.whatsapp_case_identities.resolution_status <> 'CONFIRMED';

  -- Trigger advisory requested-lines & interpretations materialisation
  v_event_key := 'packet-ai:' || p_interpretation_id::text;

  insert into public.whatsapp_case_events (
    case_id,
    event_type,
    actor_id,
    actor_type,
    correlation_key,
    resulting_state,
    metadata
  ) values (
    v_case.id,
    'AI_CONCLUSION_READY',
    null,
    'SYSTEM',
    v_event_key,
    jsonb_build_object(
      'case_type', v_case_type,
      'case_status', v_case.status
    ),
    jsonb_build_object(
      'packet_id', p_packet_id,
      'packet_ai_interpretation_id', p_interpretation_id,
      'content_fingerprint', v_ai.content_fingerprint,
      'model_version', v_ai.model_version,
      'intent', v_intent,
      'summary', coalesce(v_conclusion ->> 'summary', ''),
      'confidence', v_ai.interpretation -> 'confidence',
      'ambiguity_count', v_ambiguity_count,
      'recommended_action', v_recommended_action,
      'primary_department', v_primary_department,
      'contributor_departments', v_contributors,
      'reply_clearance', v_reply_clearance,
      'draft_reply', v_draft_reply,
      'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  -- CORE-A: Execute deterministic validation & governed field materialisation
  v_autonomy := public.whatsapp_evaluate_and_materialize_order_autonomy(
    p_packet_id,
    p_interpretation_id,
    p_job_id,
    p_lease_token,
    p_packet_revision
  );

  v_autonomy_outcome := v_autonomy->>'autonomy_outcome';
  v_human_decision_required := coalesce((v_autonomy->>'human_decision_required')::boolean, (v_autonomy_outcome <> 'AUTO_ELIGIBLE'));

  -- Refresh case after autonomy mutations
  select * into v_case from public.whatsapp_communication_cases where id = v_case.id;

  return jsonb_build_object(
    'case_id', v_case.id,
    'packet_id', p_packet_id,
    'interpretation_id', p_interpretation_id,
    'case_type', v_case.case_type,
    'status', v_case.status,
    'accountability_status', v_case.accountability_status,
    'autonomy_outcome', v_autonomy_outcome,
    'autonomy_decision_id', v_autonomy->>'decision_id',
    'governed_facts', v_autonomy->'governed_facts',
    'readiness', v_autonomy->'readiness',
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', v_human_decision_required,
    'idempotent_replay', coalesce((v_autonomy->>'idempotent_replay')::boolean, false)
  );
end;
$$;

comment on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint) is
  'Service-role-only bridge from append-only packet AI interpretation to governed commercial autonomy and communication case. Validates dispatch lease, executes deterministic Core validation, and materialises governed facts.';

revoke all on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  to service_role;

commit;
