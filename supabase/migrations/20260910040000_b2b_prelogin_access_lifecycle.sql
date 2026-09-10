-- B2B pre-login access lifecycle.
-- Restores the product contract: an applicant may request B2B access before login.
-- Identity is claimed only after staff approval and a provider-confirmed Supabase phone session.

create or replace function public.normalize_b2b_access_mobile_v2(p_phone text)
returns text
language sql
immutable
strict
set search_path = pg_catalog
as $$
  with digits as (
    select regexp_replace(p_phone, '[^0-9]', '', 'g') as d
  )
  select case
    when length(d) = 10 then '91' || d
    when length(d) = 11 and left(d, 1) = '0' then '91' || substr(d, 2)
    when length(d) = 12 and left(d, 2) = '91' then d
    else d
  end
  from digits
$$;

revoke all on function public.normalize_b2b_access_mobile_v2(text) from public, anon, authenticated;
grant execute on function public.normalize_b2b_access_mobile_v2(text) to service_role;

-- Harden the existing public.users trigger guard while this migration depends on
-- governed server-side buyer activation. A custom GUC is client-settable and is
-- therefore not authority. SECURITY INVOKER preserves the current_user of the
-- statement: direct PostgREST writes remain `authenticated`, while trusted
-- SECURITY DEFINER RPC writes execute as their postgres owner.
create or replace function public.protect_user_privilege_fields()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
begin
  if current_user in ('postgres', 'service_role') then
    return new;
  end if;

  if auth.uid() is null or old.id is distinct from auth.uid() or new.id is distinct from old.id then
    raise exception 'user profile update not permitted';
  end if;

  if new.company_id is distinct from old.company_id
     or new.role is distinct from old.role
     or new.department is distinct from old.department
     or new.designation is distinct from old.designation
     or new.is_active is distinct from old.is_active
     or new.invite_status is distinct from old.invite_status
     or new.commission_rate_percentage is distinct from old.commission_rate_percentage
     or new.is_sales_executive is distinct from old.is_sales_executive
     or new.deleted_at is distinct from old.deleted_at
     or new.created_at is distinct from old.created_at
     or new.joined_at is distinct from old.joined_at then
    raise exception 'privileged user fields require governed server authority';
  end if;

  return new;
end;
$$;

-- Profile trigger guards use the same non-forgeable execution boundary. Internal
-- staff retain their existing RLS-authorised profile-management path; ordinary
-- users cannot turn a custom setting into approval/company/price authority.
create or replace function public.prevent_profile_insert_privilege_escalation()
returns trigger
language plpgsql
security invoker
set search_path to 'public'
as $$
begin
  if current_user in ('postgres', 'service_role')
     or public.is_internal_staff(auth.uid()) then
    return new;
  end if;

  new.role := 'pending_buyer';
  new.is_approved := false;
  new.status := 'pending';
  new.company_id := null;
  new.price_tier := null;
  new.credit_limit := 0;
  return new;
end;
$$;

create or replace function public.prevent_profile_privilege_escalation()
returns trigger
language plpgsql
security invoker
set search_path to 'public'
as $$
begin
  if current_user in ('postgres', 'service_role')
     or public.is_internal_staff(auth.uid()) then
    return new;
  end if;

  if new.role is distinct from old.role then
    new.role := old.role;
  end if;
  if to_jsonb(new) ? 'is_approved'
     and (to_jsonb(new)->>'is_approved') is distinct from (to_jsonb(old)->>'is_approved') then
    new := jsonb_populate_record(new, jsonb_build_object('is_approved', to_jsonb(old)->'is_approved'));
  end if;
  if to_jsonb(new) ? 'status'
     and (to_jsonb(new)->>'status') is distinct from (to_jsonb(old)->>'status') then
    new := jsonb_populate_record(new, jsonb_build_object('status', to_jsonb(old)->'status'));
  end if;
  if to_jsonb(new) ? 'price_tier'
     and (to_jsonb(new)->>'price_tier') is distinct from (to_jsonb(old)->>'price_tier') then
    new := jsonb_populate_record(new, jsonb_build_object('price_tier', to_jsonb(old)->'price_tier'));
  end if;
  if new.company_id is distinct from old.company_id then
    new.company_id := old.company_id;
  end if;
  if to_jsonb(new) ? 'credit_limit'
     and (to_jsonb(new)->>'credit_limit') is distinct from (to_jsonb(old)->>'credit_limit') then
    new := jsonb_populate_record(new, jsonb_build_object('credit_limit', to_jsonb(old)->'credit_limit'));
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_profile_insert_privilege_escalation() from public, anon, authenticated;
grant all on function public.prevent_profile_insert_privilege_escalation() to service_role;
revoke all on function public.prevent_profile_privilege_escalation() from public, anon, authenticated;
grant all on function public.prevent_profile_privilege_escalation() to service_role;

create or replace function public.submit_b2b_access_request_v2(
  p_business_name text,
  p_contact_name text,
  p_contact_email text,
  p_contact_phone text,
  p_gst_number text default null,
  p_registered_address text default null,
  p_preferred_dispatch text default null,
  p_preferred_dispatch_other_name text default null,
  p_trade_declaration boolean default false,
  p_data_consent boolean default false
)
returns table (
  application_id uuid,
  application_status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_email text := lower(btrim(coalesce(p_contact_email, '')));
  v_mobile text := public.normalize_b2b_access_mobile_v2(coalesce(p_contact_phone, ''));
  v_existing public.b2b_applications%rowtype;
  v_app_id uuid;
begin
  if coalesce(btrim(p_business_name), '') = '' then
    raise exception 'VALIDATION_FAILED: business_name is required' using errcode = '22023';
  end if;
  if coalesce(btrim(p_contact_name), '') = '' then
    raise exception 'VALIDATION_FAILED: contact_name is required' using errcode = '22023';
  end if;
  if v_email = '' or position('@' in v_email) <= 1 then
    raise exception 'VALIDATION_FAILED: valid contact_email is required' using errcode = '22023';
  end if;
  if v_mobile is null or length(v_mobile) < 10 or length(v_mobile) > 15 then
    raise exception 'VALIDATION_FAILED: valid contact_phone is required' using errcode = '22023';
  end if;
  if not coalesce(p_trade_declaration, false) or not coalesce(p_data_consent, false) then
    raise exception 'VALIDATION_FAILED: trade_declaration and data_consent must both be accepted'
      using errcode = '22023';
  end if;

  select *
    into v_existing
  from public.b2b_applications a
  where lower(btrim(coalesce(a.contact_email, ''))) = v_email
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
  order by a.created_at desc nulls last
  limit 1;

  if found then
    return query select v_existing.id, v_existing.status, true;
    return;
  end if;

  begin
    insert into public.b2b_applications (
      business_name,
      contact_name,
      contact_person,
      contact_email,
      contact_phone,
      mobile_number,
      gst_number,
      registered_address,
      preferred_dispatch,
      preferred_dispatch_other_name,
      trade_declaration,
      data_consent,
      user_id,
      resolved_company_id,
      status
    ) values (
      btrim(p_business_name),
      btrim(p_contact_name),
      btrim(p_contact_name),
      v_email,
      btrim(p_contact_phone),
      v_mobile,
      nullif(btrim(p_gst_number), ''),
      nullif(btrim(p_registered_address), ''),
      nullif(btrim(p_preferred_dispatch), ''),
      case
        when upper(coalesce(btrim(p_preferred_dispatch), '')) = 'OTHER'
          then nullif(btrim(p_preferred_dispatch_other_name), '')
        else null
      end,
      true,
      true,
      null,
      null,
      'pending'
    )
    returning id into v_app_id;
  exception when unique_violation then
    select *
      into v_existing
    from public.b2b_applications a
    where lower(btrim(coalesce(a.contact_email, ''))) = v_email
      and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
    order by a.created_at desc nulls last
    limit 1;

    if found then
      return query select v_existing.id, v_existing.status, true;
      return;
    end if;
    raise;
  end;

  return query select v_app_id, 'pending'::text, false;
end;
$$;

revoke all on function public.submit_b2b_access_request_v2(
  text,text,text,text,text,text,text,text,boolean,boolean
) from public;
grant execute on function public.submit_b2b_access_request_v2(
  text,text,text,text,text,text,text,text,boolean,boolean
) to anon, authenticated, service_role;

-- Remove the generic direct client write surface. Public intake now goes only
-- through submit_b2b_access_request_v2; the authenticated v1 RPC is
-- SECURITY DEFINER and remains functional.
revoke insert on table public.b2b_applications from public, anon, authenticated;

create or replace function public.approve_b2b_access_request_v2(
  p_application_id uuid,
  p_assigned_price_tier text,
  p_admin_notes text default null
)
returns table (
  application_id uuid,
  application_status text,
  company_id uuid,
  identity_activation_required boolean
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := auth.uid();
  v_app public.b2b_applications%rowtype;
  v_company_id uuid;
  v_gst_norm text;
begin
  if v_staff is null or not public.is_internal_staff(v_staff) then
    raise exception 'STAFF_AUTHORITY_REQUIRED: only internal staff may approve a trade application'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_assigned_price_tier), '') = '' then
    raise exception 'VALIDATION_FAILED: assigned_price_tier is required' using errcode = '22023';
  end if;

  select * into v_app
  from public.b2b_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  if v_app.status = 'approved' and v_app.resolved_company_id is not null then
    return query
      select v_app.id, v_app.status, v_app.resolved_company_id, (v_app.user_id is null);
    return;
  end if;

  if coalesce(v_app.status, '') not in ('pending', 'approved') then
    raise exception 'APPLICATION_NOT_PENDING: application % is in status %',
      p_application_id, v_app.status using errcode = 'P0001';
  end if;

  v_company_id := v_app.resolved_company_id;
  v_gst_norm := nullif(upper(regexp_replace(coalesce(v_app.gst_number, ''), '\s', '', 'g')), '');

  if v_gst_norm is not null
     and v_gst_norm !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
    v_gst_norm := null;
  end if;

  if v_company_id is null and v_gst_norm is not null then
    perform pg_advisory_xact_lock(hashtextextended('b2b_company_gst:' || v_gst_norm, 0));
    select c.id into v_company_id
    from public.companies c
    where c.gst_number is not null
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_gst_norm
      and upper(regexp_replace(c.gst_number, '\s', '', 'g'))
          ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
    limit 1;
  end if;

  if v_company_id is null then
    begin
      insert into public.companies (
        business_name, gst_number, phone, registered_address, status, price_tier
      ) values (
        btrim(v_app.business_name), v_app.gst_number,
        coalesce(v_app.mobile_number, v_app.contact_phone),
        v_app.registered_address, 'pending', btrim(p_assigned_price_tier)
      )
      returning id into v_company_id;
    exception when unique_violation then
      if v_gst_norm is null then
        raise;
      end if;
      select c.id into v_company_id
      from public.companies c
      where c.gst_number is not null
        and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_gst_norm
        and upper(regexp_replace(c.gst_number, '\s', '', 'g'))
            ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
      limit 1;
      if v_company_id is null then
        raise;
      end if;
    end;
  else
    update public.companies
    set price_tier = coalesce(nullif(btrim(p_assigned_price_tier), ''), price_tier)
    where id = v_company_id;
  end if;

  perform set_config('app.b2b_application_rpc_managed', 'on', true);

  update public.b2b_applications
  set status = 'approved',
      reviewed_by = v_staff,
      reviewed_at = now(),
      assigned_price_tier = btrim(p_assigned_price_tier),
      admin_notes = coalesce(p_admin_notes, admin_notes),
      rejection_reason = null,
      resolved_company_id = v_company_id,
      updated_at = now()
  where id = p_application_id;

  perform set_config('app.b2b_application_rpc_managed', 'off', true);

  if v_app.user_id is null then
    insert into public.audit_logs (
      action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
    ) values (
      'B2B_ACCESS_REQUEST_APPROVED_PENDING_IDENTITY',
      'b2b_onboarding',
      'b2b_applications',
      p_application_id::text,
      v_staff,
      p_admin_notes,
      jsonb_build_object(
        'company_id', v_company_id,
        'assigned_price_tier', p_assigned_price_tier,
        'identity_activation_required', true
      ),
      'high'
    );

    return query select p_application_id, 'approved'::text, v_company_id, true;
    return;
  end if;

  update public.companies
  set status = 'active',
      price_tier = coalesce(nullif(btrim(p_assigned_price_tier), ''), price_tier)
  where id = v_company_id;

  perform set_config('oasis.staff_authority', 'governed', true);

  update public.users
  set role = 'b2b_buyer',
      company_id = v_company_id,
      is_active = true,
      invite_status = 'accepted'
  where id = v_app.user_id;

  insert into public.profiles (
    id, company_id, full_name, email, role, mobile_number,
    is_approved, status, price_tier
  ) values (
    v_app.user_id, v_company_id,
    coalesce(nullif(btrim(v_app.contact_person), ''), nullif(btrim(v_app.contact_name), '')),
    v_app.contact_email, 'b2b_buyer',
    coalesce(v_app.mobile_number, v_app.contact_phone),
    true, 'approved', btrim(p_assigned_price_tier)
  )
  on conflict (id) do update set
    company_id = excluded.company_id,
    full_name = coalesce(public.profiles.full_name, excluded.full_name),
    email = coalesce(public.profiles.email, excluded.email),
    role = excluded.role,
    mobile_number = coalesce(public.profiles.mobile_number, excluded.mobile_number),
    is_approved = true,
    status = 'approved',
    price_tier = excluded.price_tier;

  perform set_config('oasis.staff_authority', 'off', true);

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
  ) values (
    'B2B_ACCESS_REQUEST_APPROVED_AND_ACTIVATED',
    'b2b_onboarding',
    'b2b_applications',
    p_application_id::text,
    v_staff,
    p_admin_notes,
    jsonb_build_object(
      'company_id', v_company_id,
      'user_id', v_app.user_id,
      'assigned_price_tier', p_assigned_price_tier,
      'identity_activation_required', false
    ),
    'high'
  );

  return query select p_application_id, 'approved'::text, v_company_id, false;
end;
$$;

revoke all on function public.approve_b2b_access_request_v2(uuid,text,text) from public, anon, authenticated;
grant execute on function public.approve_b2b_access_request_v2(uuid,text,text) to authenticated, service_role;

create or replace function public.claim_approved_b2b_access_request_v2()
returns table (
  application_id uuid,
  claimed boolean,
  company_id uuid,
  already_active boolean
)
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_uid uuid := auth.uid();
  v_auth_phone text;
  v_auth_phone_confirmed_at timestamptz;
  v_mobile text;
  v_match_ids uuid[];
  v_app public.b2b_applications%rowtype;
  v_email text;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: an authenticated session is required' using errcode = '28000';
  end if;

  if public.is_internal_staff(v_uid) then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  select u.phone, u.phone_confirmed_at, u.email
  into v_auth_phone, v_auth_phone_confirmed_at, v_email
  from auth.users u
  where u.id = v_uid;

  if v_auth_phone is null or v_auth_phone_confirmed_at is null then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  v_mobile := public.normalize_b2b_access_mobile_v2(v_auth_phone);
  if v_mobile is null or length(v_mobile) < 10 or length(v_mobile) > 15 then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  select a.*
  into v_app
  from public.b2b_applications a
  where a.status = 'approved'
    and a.user_id = v_uid
  order by a.reviewed_at desc nulls last, a.created_at desc nulls last
  limit 1;

  if found then
    return query select v_app.id, false, v_app.resolved_company_id, true;
    return;
  end if;

  select array_agg(a.id order by a.reviewed_at desc nulls last, a.created_at desc nulls last)
  into v_match_ids
  from public.b2b_applications a
  where a.status = 'approved'
    and a.user_id is null
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile;

  if coalesce(cardinality(v_match_ids), 0) = 0 then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  if cardinality(v_match_ids) <> 1 then
    raise exception 'AMBIGUOUS_APPROVED_APPLICATION: more than one approved application matches the verified mobile'
      using errcode = 'P0001';
  end if;

  select * into v_app
  from public.b2b_applications
  where id = v_match_ids[1]
  for update;

  if v_app.resolved_company_id is null then
    raise exception 'APPLICATION_INCOMPLETE: approved application has no resolved company'
      using errcode = 'P0001';
  end if;

  update public.b2b_applications
  set user_id = v_uid,
      updated_at = now()
  where id = v_app.id
    and user_id is null;

  if not found then
    raise exception 'APPLICATION_ALREADY_CLAIMED: approved application was claimed concurrently'
      using errcode = '40001';
  end if;

  update public.companies
  set status = 'active',
      price_tier = coalesce(v_app.assigned_price_tier, price_tier)
  where id = v_app.resolved_company_id;

  perform set_config('oasis.staff_authority', 'governed', true);

  update public.users
  set role = 'b2b_buyer',
      company_id = v_app.resolved_company_id,
      is_active = true,
      invite_status = 'accepted'
  where id = v_uid;

  if not found then
    insert into public.users (id, email, role, company_id, is_active, invite_status)
    values (v_uid, v_email, 'b2b_buyer', v_app.resolved_company_id, true, 'accepted');
  end if;

  insert into public.profiles (
    id, company_id, full_name, email, role, mobile_number,
    is_approved, status, price_tier
  ) values (
    v_uid,
    v_app.resolved_company_id,
    coalesce(nullif(btrim(v_app.contact_person), ''), nullif(btrim(v_app.contact_name), '')),
    coalesce(v_app.contact_email, v_email),
    'b2b_buyer',
    v_auth_phone,
    true,
    'approved',
    v_app.assigned_price_tier
  )
  on conflict (id) do update set
    company_id = excluded.company_id,
    full_name = coalesce(public.profiles.full_name, excluded.full_name),
    email = coalesce(public.profiles.email, excluded.email),
    role = excluded.role,
    mobile_number = coalesce(public.profiles.mobile_number, excluded.mobile_number),
    is_approved = true,
    status = 'approved',
    price_tier = coalesce(excluded.price_tier, public.profiles.price_tier);

  perform set_config('oasis.staff_authority', 'off', true);

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
  ) values (
    'B2B_ACCESS_REQUEST_IDENTITY_CLAIMED',
    'b2b_onboarding',
    'b2b_applications',
    v_app.id::text,
    v_uid,
    'Provider-confirmed mobile claimed approved B2B access request',
    jsonb_build_object(
      'company_id', v_app.resolved_company_id,
      'user_id', v_uid
    ),
    'high'
  );

  return query select v_app.id, true, v_app.resolved_company_id, false;
end;
$$;

revoke all on function public.claim_approved_b2b_access_request_v2() from public, anon;
grant execute on function public.claim_approved_b2b_access_request_v2() to authenticated, service_role;

comment on function public.submit_b2b_access_request_v2(
  text,text,text,text,text,text,text,text,boolean,boolean
) is
  'Pre-login B2B access intake. Creates only a safe pending application; no Auth identity, company activation, role, credit, or price authority is granted.';

comment on function public.approve_b2b_access_request_v2(uuid,text,text) is
  'Staff approval for pre-login B2B access. Anonymous applications are approved pending provider-verified identity activation; legacy authenticated applications are activated immediately.';

comment on function public.claim_approved_b2b_access_request_v2() is
  'Post-approval B2B identity claim. Uses only the current auth.users provider-confirmed phone to bind exactly one approved unclaimed application and activate buyer/company authority.';
