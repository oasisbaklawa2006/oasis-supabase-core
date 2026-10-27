-- WA450-D3: Anchor WhatsApp commercial customer identity on verified sender/contact
-- binding. Message-body GSTIN, name, and third-party phone clues are hints only and
-- must not resolve to another customer's company without sender authorization.
--
-- Rollback: forward-only policy — restore prior function body from
-- 20261011150000_mc631_so_recordable_progressive_identity.sql if an approved
-- corrective migration is required; do not drop audit data.

create or replace function public.whatsapp_contact_is_verified_staff(p_contact_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.whatsapp_contacts wc
    join public.users u on (
      u.id = wc.id
      or lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'))
         = lower(regexp_replace(coalesce(wc.phone_number, ''), '\D', '', 'g'))
      or u.email = wc.phone_number
    )
    where wc.id = p_contact_id
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
  );
$$;

revoke all on function public.whatsapp_contact_is_verified_staff(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_contact_is_verified_staff(uuid) to service_role;

create or replace function public.whatsapp_sender_identity_anchor_company_ids(p_contact_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_contact public.whatsapp_contacts%rowtype;
  v_phone text;
  v_phone_company_ids uuid[];
  v_auth_company_ids uuid[];
begin
  select * into v_contact from public.whatsapp_contacts where id = p_contact_id;
  if not found then
    return '{}'::uuid[];
  end if;

  v_phone := lower(regexp_replace(coalesce(v_contact.phone_number, ''), '\D', '', 'g'));

  if public.whatsapp_contact_is_verified_staff(p_contact_id) then
    return '{}'::uuid[];
  end if;

  if length(v_phone) >= 10 then
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_phone_company_ids
    from public.companies c
    where lower(coalesce(c.status, '')) in ('active', 'approved')
      and (
        c.phone = v_phone
        or exists (
          select 1 from public.delivery_addresses da
          where da.company_id = c.id and da.contact_phone = v_phone
        )
        or exists (
          select 1 from public.b2b_applications ba
          where ba.status = 'approved'
            and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
              = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
            and (ba.contact_phone = v_phone or ba.mobile_number = v_phone)
        )
      );

    if cardinality(v_phone_company_ids) = 0 then
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
              and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
                = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
              and (
                lower(regexp_replace(coalesce(ba.contact_phone, ''), '\D', '', 'g')) = v_phone
                or lower(regexp_replace(coalesce(ba.mobile_number, ''), '\D', '', 'g')) = v_phone
              )
          )
        );
    end if;
  else
    v_phone_company_ids := '{}'::uuid[];
  end if;

  select coalesce(array_agg(distinct a.company_id), '{}'::uuid[])
  into v_auth_company_ids
  from public.whatsapp_sender_commercial_authorizations a
  join public.companies c on c.id = a.company_id
  where a.contact_id = p_contact_id
    and a.status = 'ACTIVE'
    and a.valid_until > statement_timestamp()
    and lower(coalesce(c.status, '')) in ('active', 'approved');

  return (
    select coalesce(array_agg(distinct x), '{}'::uuid[])
    from unnest(v_phone_company_ids || v_auth_company_ids) as x
  );
end;
$$;

revoke all on function public.whatsapp_sender_identity_anchor_company_ids(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_sender_identity_anchor_company_ids(uuid) to service_role;

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
  v_body_phone_unmatched boolean := false;
  v_is_verified_staff boolean := false;
  v_sender_anchor_ids uuid[];
  v_clue_method boolean := false;
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
  v_is_verified_staff := coalesce(p_candidate->>'sender_is_verified_staff', '') in ('true', '1', 'yes')
    or public.whatsapp_contact_is_verified_staff(p_contact_id);

  if p_candidate is not null
     and jsonb_typeof(p_candidate) = 'object'
     and coalesce(p_candidate->>'multiple_gst_hints', '') in ('true', '1', 'yes') then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'AMBIGUOUS'::text, 'HELD_FOR_VERIFICATION'::text, 0.2::numeric,
      jsonb_build_object(
        'reason', 'multiple_gst_hints_in_message',
        'candidate', coalesce(p_candidate, '{}'::jsonb)
      );
    return;
  end if;

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
    if length(v_body_phone) >= 10
       and v_body_phone is distinct from public.whatsapp_normalize_identity_phone(v_phone) then
      v_has_explicit_candidate := true;
      v_body_company_ids := public.whatsapp_match_companies_by_normalized_phone(v_body_phone);
      if cardinality(v_body_company_ids) = 1 then
        v_body_phone_company_id := v_body_company_ids[1];
        v_method := 'MESSAGE_BODY_PHONE_MATCH';
        v_clue_method := true;
      elsif cardinality(v_body_company_ids) > 1 then
        return query select
          null::uuid, null::text, null::text, null::text, false,
          'AMBIGUOUS'::text, 'MULTIPLE_BODY_PHONE_MATCHES'::text, 0.5::numeric,
          jsonb_build_object('body_phone', v_body_phone, 'matched_company_ids', to_jsonb(v_body_company_ids));
        return;
      elsif cardinality(v_body_company_ids) = 0 then
        v_body_phone_unmatched := true;
      end if;
    end if;
  end if;

  -- Priority 1: Explicit candidate GST match (hint only; authorization gate before RESOLVED)
  if p_candidate is not null and jsonb_typeof(p_candidate) = 'object' then
    if nullif(btrim(coalesce(p_candidate->>'gst_number', '')), '') is not null then
      v_has_explicit_candidate := true;
      v_candidate_gst := upper(regexp_replace(p_candidate->>'gst_number', '\s', '', 'g'));

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
            v_clue_method := true;
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
        select coalesce(array_agg(distinct c.id), '{}'::uuid[])
        into v_gst_company_ids
        from public.companies c
        where upper(regexp_replace(coalesce(c.gst_number, ''), '[^a-zA-Z0-9]', '', 'g')) = upper(regexp_replace(v_candidate_gst, '[^a-zA-Z0-9]', '', 'g'))
          and lower(coalesce(c.status, '')) in ('active', 'approved');

        if cardinality(v_gst_company_ids) = 1 then
          v_gst_explicit_company_id := v_gst_company_ids[1];
          if v_method is null then
            v_method := 'EXACT_GST_MATCH';
            v_clue_method := true;
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

  if v_body_phone_unmatched and v_gst_explicit_company_id is null then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'UNRESOLVED'::text, 'BODY_PHONE_NOT_FOUND_OR_INACTIVE'::text, 0.0::numeric,
      jsonb_build_object('body_phone', v_body_phone);
    return;
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

  -- Priority 2: Explicit candidate company/business name match
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

  if v_has_explicit_candidate and v_target_company_id is null then
    return query select
      null::uuid, null::text, null::text, null::text, false,
      'UNRESOLVED'::text, 'EXPLICIT_CANDIDATE_UNRESOLVED'::text, 0.0::numeric,
      jsonb_build_object('candidate', coalesce(p_candidate, '{}'::jsonb));
    return;
  end if;

  -- Priority 3: Active sender commercial authorization (only when no message clue target)
  if v_target_company_id is null
     and not public.whatsapp_contact_is_verified_staff(p_contact_id) then
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

  -- Priority 4: Exact sender phone match
  if v_target_company_id is null and length(v_phone) >= 10
     and not public.whatsapp_contact_is_verified_staff(p_contact_id) then
    select coalesce(array_agg(distinct c.id), '{}'::uuid[])
    into v_phone_company_ids
    from public.companies c
    where lower(coalesce(c.status, '')) in ('active', 'approved')
      and (
        c.phone = v_phone
        or exists (
          select 1 from public.delivery_addresses da
          where da.company_id = c.id and da.contact_phone = v_phone
        )
        or exists (
          select 1 from public.b2b_applications ba
          where ba.status = 'approved'
            and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
              = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
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
              and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
                = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
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

  if v_target_company_id is not null then
    select * into v_company from public.companies where id = v_target_company_id;
    if not found or lower(coalesce(v_company.status, '')) not in ('active', 'approved') then
      return query select
        null::uuid, null::text, null::text, null::text, false,
        'UNRESOLVED'::text, 'COMPANY_NOT_ACTIVE'::text, 0.0::numeric,
        jsonb_build_object('company_id', v_target_company_id);
      return;
    end if;

    -- WA450-D3: message clues must not authenticate a different company than the sender binding.
    if v_clue_method
       and v_method not in ('EXACT_PHONE_MATCH', 'ACTIVE_COMMERCIAL_AUTHORIZATION') then
      if v_is_verified_staff then
        if not exists (
          select 1
          from public.whatsapp_sender_commercial_authorizations a
          where a.contact_id = p_contact_id
            and a.company_id = v_target_company_id
            and a.status = 'ACTIVE'
            and a.valid_until > statement_timestamp()
        ) then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'HELD_FOR_VERIFICATION'::text, 0.2::numeric,
            jsonb_build_object(
              'reason', 'staff_message_clue_without_delegated_authorization',
              'target_company_id', v_target_company_id,
              'match_method', v_method,
              'candidate', coalesce(p_candidate, '{}'::jsonb)
            );
          return;
        end if;
      else
        v_sender_anchor_ids := public.whatsapp_sender_identity_anchor_company_ids(p_contact_id);
        if cardinality(v_sender_anchor_ids) = 0 then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'HELD_FOR_VERIFICATION'::text, 0.2::numeric,
            jsonb_build_object(
              'reason', 'unbound_sender_message_clue_only',
              'target_company_id', v_target_company_id,
              'match_method', v_method,
              'candidate', coalesce(p_candidate, '{}'::jsonb)
            );
          return;
        elsif not v_target_company_id = any (v_sender_anchor_ids) then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'HELD_FOR_VERIFICATION'::text, 0.2::numeric,
            jsonb_build_object(
              'reason', 'identity_clue_conflicts_with_sender_binding',
              'target_company_id', v_target_company_id,
              'sender_anchor_company_ids', to_jsonb(v_sender_anchor_ids),
              'match_method', v_method,
              'candidate', coalesce(p_candidate, '{}'::jsonb)
            );
          return;
        elsif cardinality(v_sender_anchor_ids) > 1 then
          return query select
            null::uuid, null::text, null::text, null::text, false,
            'AMBIGUOUS'::text, 'HELD_FOR_VERIFICATION'::text, 0.2::numeric,
            jsonb_build_object(
              'reason', 'ambiguous_sender_binding_with_message_clue',
              'target_company_id', v_target_company_id,
              'sender_anchor_company_ids', to_jsonb(v_sender_anchor_ids),
              'match_method', v_method,
              'candidate', coalesce(p_candidate, '{}'::jsonb)
            );
          return;
        end if;
      end if;
    end if;

    return query select
      v_company.id,
      v_company.business_name,
      v_company.gst_number,
      v_company.payment_terms,
      coalesce(v_company.is_frozen, false),
      'RESOLVED'::text,
      v_method,
      case when v_clue_method and v_method = 'EXACT_GST_MATCH' then 0.95::numeric else 1.0::numeric end,
      jsonb_build_object(
        'company_id', v_company.id,
        'business_name', v_company.business_name,
        'gst_number', v_company.gst_number,
        'payment_terms', v_company.payment_terms,
        'is_frozen', v_company.is_frozen,
        'status', v_company.status,
        'match_method', v_method,
        'identity_anchor', 'sender_binding_verified'
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
