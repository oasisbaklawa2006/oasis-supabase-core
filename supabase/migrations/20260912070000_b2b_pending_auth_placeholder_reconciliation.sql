-- Issue #292 / Central #561: governed compatibility for legacy PENDING phone
-- placeholders that pre-date the canonical MSG91 Auth identity chain.
--
-- This migration does not repair any production row by itself. It adds two
-- service-role-only RPCs used only after MSG91 has independently verified the
-- phone number. The first is a read-only preflight. The second atomically
-- retires one proven non-authoritative placeholder and binds the newly-created
-- confirmed Auth identity to public.users. Staff/company/ambiguous identities
-- fail closed.

create or replace function public.inspect_b2b_pending_phone_placeholder_v1(
  p_verified_phone text
)
returns table (
  placeholder_user_id uuid,
  application_id uuid,
  eligible boolean,
  reason text
)
language plpgsql
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  v_mobile text := public.normalize_b2b_access_mobile_v2(coalesce(p_verified_phone, ''));
  v_public_ids uuid[];
  v_auth_ids uuid[];
  v_application_ids uuid[];
  v_old public.users%rowtype;
begin
  if v_mobile is null or length(v_mobile) <> 12 or left(v_mobile, 2) <> '91' then
    return query select null::uuid, null::uuid, false, 'phone_invalid'::text;
    return;
  end if;

  select array_agg(distinct u.id order by u.id)
    into v_public_ids
  from public.users u
  where public.normalize_b2b_access_mobile_v2(coalesce(u.phone, '')) = v_mobile
     or public.normalize_b2b_access_mobile_v2(coalesce(u.mobile_number, '')) = v_mobile
     or exists (
       select 1
       from unnest(coalesce(u.secondary_phones, array[]::text[])) as p(phone)
       where public.normalize_b2b_access_mobile_v2(coalesce(p.phone, '')) = v_mobile
     );

  if coalesce(cardinality(v_public_ids), 0) = 0 then
    return query select null::uuid, null::uuid, false, 'placeholder_not_found'::text;
    return;
  end if;

  if cardinality(v_public_ids) <> 1 then
    return query select null::uuid, null::uuid, false, 'ambiguous_public_identity'::text;
    return;
  end if;

  select array_agg(au.id order by au.id)
    into v_auth_ids
  from auth.users au
  where public.normalize_b2b_access_mobile_v2(coalesce(au.phone, '')) = v_mobile;

  if coalesce(cardinality(v_auth_ids), 0) > 0 then
    return query select v_public_ids[1], null::uuid, false, 'auth_phone_already_owned'::text;
    return;
  end if;

  select * into v_old
  from public.users
  where id = v_public_ids[1];

  if upper(coalesce(v_old.role, '')) not in ('PENDING', 'PENDING_BUYER')
     or v_old.company_id is not null
     or v_old.department is not null
     or v_old.designation is not null
     or coalesce(v_old.is_sales_executive, false)
     or v_old.deleted_at is not null
     or v_old.is_active is false
     or public.is_internal_staff(v_old.id)
     or exists (select 1 from public.profiles p where p.id = v_old.id)
     or exists (select 1 from public.user_role_map rm where rm.user_id = v_old.id)
     or exists (select 1 from public.companies c where c.account_manager_id = v_old.id)
  then
    return query select v_old.id, null::uuid, false, 'authoritative_identity_not_placeholder'::text;
    return;
  end if;

  select array_agg(a.id order by a.created_at desc nulls last, a.id)
    into v_application_ids
  from public.b2b_applications a
  where lower(coalesce(a.status, '')) in ('pending', 'approved')
    and a.user_id is null
    and public.normalize_b2b_access_mobile_v2(
      coalesce(a.mobile_number, a.contact_phone, '')
    ) = v_mobile;

  if coalesce(cardinality(v_application_ids), 0) = 0 then
    return query select v_old.id, null::uuid, false, 'application_context_missing'::text;
    return;
  end if;

  if cardinality(v_application_ids) <> 1 then
    return query select v_old.id, null::uuid, false, 'ambiguous_application_context'::text;
    return;
  end if;

  return query select v_old.id, v_application_ids[1], true, 'eligible'::text;
end;
$$;

revoke all on function public.inspect_b2b_pending_phone_placeholder_v1(text) from public, anon, authenticated;
grant execute on function public.inspect_b2b_pending_phone_placeholder_v1(text) to service_role;

comment on function public.inspect_b2b_pending_phone_placeholder_v1(text) is
  'Service-only preflight for MSG91 compatibility. It identifies exactly one non-authoritative legacy PENDING/no-company/no-Auth phone placeholder tied to exactly one pending/approved unclaimed B2B application. No mutation is performed.';

create or replace function public.reconcile_b2b_pending_phone_placeholder_v1(
  p_verified_phone text,
  p_expected_placeholder_user_id uuid,
  p_new_auth_user_id uuid
)
returns table (
  reconciled boolean,
  replayed boolean,
  canonical_user_id uuid,
  application_id uuid
)
language plpgsql
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  v_mobile text := public.normalize_b2b_access_mobile_v2(coalesce(p_verified_phone, ''));
  v_auth_phone text;
  v_auth_confirmed_at timestamptz;
  v_auth_email text;
  v_auth_ids uuid[];
  v_public_ids uuid[];
  v_application_ids uuid[];
  v_old public.users%rowtype;
  v_existing public.users%rowtype;
begin
  if v_mobile is null or length(v_mobile) <> 12 or left(v_mobile, 2) <> '91' then
    raise exception 'B2B_PLACEHOLDER_PHONE_INVALID' using errcode = '22023';
  end if;
  if p_expected_placeholder_user_id is null or p_new_auth_user_id is null then
    raise exception 'B2B_PLACEHOLDER_ID_REQUIRED' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('b2b_pending_phone:' || v_mobile, 0));

  select au.phone, au.phone_confirmed_at, au.email
    into v_auth_phone, v_auth_confirmed_at, v_auth_email
  from auth.users au
  where au.id = p_new_auth_user_id;

  if not found
     or v_auth_confirmed_at is null
     or public.normalize_b2b_access_mobile_v2(coalesce(v_auth_phone, '')) <> v_mobile
  then
    raise exception 'B2B_PLACEHOLDER_CONFIRMED_AUTH_REQUIRED' using errcode = '42501';
  end if;

  select array_agg(au.id order by au.id)
    into v_auth_ids
  from auth.users au
  where public.normalize_b2b_access_mobile_v2(coalesce(au.phone, '')) = v_mobile;

  if cardinality(v_auth_ids) <> 1 or v_auth_ids[1] <> p_new_auth_user_id then
    raise exception 'B2B_PLACEHOLDER_AUTH_PHONE_CONFLICT' using errcode = 'P0001';
  end if;

  -- Idempotent retry after a committed reconciliation or after the subsequent
  -- approved-application claim has already promoted this same canonical user.
  select * into v_existing
  from public.users u
  where u.id = p_new_auth_user_id;

  if found then
    if public.normalize_b2b_access_mobile_v2(coalesce(v_existing.phone, v_existing.mobile_number, '')) <> v_mobile
       or upper(coalesce(v_existing.role, '')) not in ('PENDING', 'PENDING_BUYER', 'B2B_BUYER')
       or v_existing.is_active is false
       or v_existing.deleted_at is not null
    then
      raise exception 'B2B_PLACEHOLDER_REPLAY_CONFLICT' using errcode = 'P0001';
    end if;

    select a.id into application_id
    from public.b2b_applications a
    where public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
      and lower(coalesce(a.status, '')) = 'approved'
      and (a.user_id is null or a.user_id = p_new_auth_user_id)
    order by a.reviewed_at desc nulls last, a.created_at desc nulls last
    limit 1;

    return query select false, true, p_new_auth_user_id, application_id;
    return;
  end if;

  select array_agg(distinct u.id order by u.id)
    into v_public_ids
  from public.users u
  where public.normalize_b2b_access_mobile_v2(coalesce(u.phone, '')) = v_mobile
     or public.normalize_b2b_access_mobile_v2(coalesce(u.mobile_number, '')) = v_mobile
     or exists (
       select 1
       from unnest(coalesce(u.secondary_phones, array[]::text[])) as p(phone)
       where public.normalize_b2b_access_mobile_v2(coalesce(p.phone, '')) = v_mobile
     );

  if cardinality(v_public_ids) <> 1 or v_public_ids[1] <> p_expected_placeholder_user_id then
    raise exception 'B2B_PLACEHOLDER_PUBLIC_IDENTITY_CONFLICT' using errcode = 'P0001';
  end if;

  select * into v_old
  from public.users
  where id = p_expected_placeholder_user_id
  for update;

  if not found
     or exists (select 1 from auth.users au where au.id = v_old.id)
     or upper(coalesce(v_old.role, '')) not in ('PENDING', 'PENDING_BUYER')
     or v_old.company_id is not null
     or v_old.department is not null
     or v_old.designation is not null
     or coalesce(v_old.is_sales_executive, false)
     or v_old.deleted_at is not null
     or v_old.is_active is false
     or public.is_internal_staff(v_old.id)
     or exists (select 1 from public.profiles p where p.id = v_old.id)
     or exists (select 1 from public.user_role_map rm where rm.user_id = v_old.id)
     or exists (select 1 from public.companies c where c.account_manager_id = v_old.id)
  then
    raise exception 'B2B_PLACEHOLDER_NOT_SAFE' using errcode = 'P0001';
  end if;

  select array_agg(a.id order by a.created_at desc nulls last, a.id)
    into v_application_ids
  from public.b2b_applications a
  where lower(coalesce(a.status, '')) in ('pending', 'approved')
    and a.user_id is null
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile;

  if cardinality(v_application_ids) <> 1 then
    raise exception 'B2B_PLACEHOLDER_APPLICATION_CONFLICT' using errcode = 'P0001';
  end if;

  if v_auth_email is not null and exists (
    select 1
    from public.users u
    where lower(btrim(coalesce(u.email, ''))) = lower(btrim(v_auth_email))
      and u.id not in (p_expected_placeholder_user_id, p_new_auth_user_id)
  ) then
    raise exception 'B2B_PLACEHOLDER_EMAIL_CONFLICT' using errcode = 'P0001';
  end if;

  -- Preserve the historical row for referential/audit lineage but remove every
  -- executable phone binding. The row becomes an inactive tombstone; no delete
  -- or primary-key rewrite is performed.
  update public.users
  set phone = null,
      mobile_number = null,
      secondary_phones = array[]::text[],
      email = case
        when v_auth_email is not null and lower(btrim(coalesce(email, ''))) = lower(btrim(v_auth_email)) then null
        else email
      end,
      is_active = false,
      invite_status = 'blocked',
      deleted_at = coalesce(deleted_at, now())
  where id = p_expected_placeholder_user_id;

  insert into public.users (
    id, email, phone, role, is_active, invite_status,
    name, full_name, preferred_language
  ) values (
    p_new_auth_user_id,
    v_auth_email,
    v_auth_phone,
    'PENDING',
    true,
    'pending',
    v_old.name,
    v_old.full_name,
    coalesce(v_old.preferred_language, 'en')
  );

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id,
    reason, old_value, new_value, risk_level
  ) values (
    'B2B_PENDING_AUTH_PLACEHOLDER_RECONCILED',
    'b2b_onboarding',
    'public.users',
    p_new_auth_user_id::text,
    null,
    'MSG91 provider-confirmed phone reconciled a legacy non-authoritative PENDING placeholder',
    jsonb_build_object(
      'placeholder_user_id', p_expected_placeholder_user_id,
      'application_id', v_application_ids[1]
    ),
    jsonb_build_object(
      'canonical_user_id', p_new_auth_user_id,
      'application_id', v_application_ids[1],
      'role', 'PENDING'
    ),
    'high'
  );

  return query select true, false, p_new_auth_user_id, v_application_ids[1];
end;
$$;

revoke all on function public.reconcile_b2b_pending_phone_placeholder_v1(text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.reconcile_b2b_pending_phone_placeholder_v1(text,uuid,uuid) to service_role;

comment on function public.reconcile_b2b_pending_phone_placeholder_v1(text,uuid,uuid) is
  'Service-only atomic compatibility repair after provider verification. Re-validates one legacy PENDING/no-company/no-Auth placeholder and one confirmed new Auth phone owner, preserves the old row as an inactive tombstone, creates the canonical public.users identity, and audits the transition. No staff/company/approved or ambiguous identity is eligible.';
