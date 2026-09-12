-- B2B Buyer email OTP authority.
--
-- Email OTP is deliberately separate from Supabase Auth's public email identity:
-- the canonical Buyer Auth identity remains the same phone-bound UUID used by
-- MSG91. A verified application email may activate that UUID through this
-- service-role-only authority, preventing parallel Buyer identities.

set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table if not exists public.b2b_email_otp_challenges (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.b2b_applications(id) on delete cascade,
  normalized_email text not null,
  otp_mac text not null,
  expires_at timestamptz not null,
  max_attempts integer not null default 5 check (max_attempts between 1 and 10),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint b2b_email_otp_normalized_email_chk
    check (normalized_email = lower(btrim(normalized_email)) and position('@' in normalized_email) > 1),
  constraint b2b_email_otp_mac_chk check (length(otp_mac) >= 32)
);

create index if not exists idx_b2b_email_otp_challenges_email_created
  on public.b2b_email_otp_challenges (normalized_email, created_at desc);
create index if not exists idx_b2b_email_otp_challenges_expiry
  on public.b2b_email_otp_challenges (expires_at)
  where consumed_at is null;

alter table public.b2b_email_otp_challenges enable row level security;
revoke all on table public.b2b_email_otp_challenges from public, anon, authenticated;
grant select, insert, update, delete on table public.b2b_email_otp_challenges to service_role;

create or replace function public.consume_b2b_email_otp_challenge_v1(
  p_challenge_id uuid,
  p_otp_mac text
)
returns table (
  verified boolean,
  application_id uuid,
  normalized_email text,
  failure_reason text
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_row public.b2b_email_otp_challenges%rowtype;
begin
  if p_challenge_id is null or coalesce(btrim(p_otp_mac), '') = '' then
    return query select false, null::uuid, null::text, 'invalid_challenge'::text;
    return;
  end if;

  select * into v_row
  from public.b2b_email_otp_challenges
  where id = p_challenge_id
  for update;

  if not found then
    return query select false, null::uuid, null::text, 'invalid_challenge'::text;
    return;
  end if;

  if v_row.consumed_at is not null then
    return query select false, null::uuid, null::text, 'challenge_consumed'::text;
    return;
  end if;

  if v_row.expires_at <= now() then
    update public.b2b_email_otp_challenges
    set consumed_at = coalesce(consumed_at, now())
    where id = v_row.id;
    return query select false, null::uuid, null::text, 'challenge_expired'::text;
    return;
  end if;

  if v_row.attempt_count >= v_row.max_attempts then
    update public.b2b_email_otp_challenges
    set consumed_at = coalesce(consumed_at, now())
    where id = v_row.id;
    return query select false, null::uuid, null::text, 'attempt_limit_reached'::text;
    return;
  end if;

  if v_row.otp_mac <> p_otp_mac then
    update public.b2b_email_otp_challenges
    set attempt_count = attempt_count + 1,
        consumed_at = case when attempt_count + 1 >= max_attempts then now() else consumed_at end
    where id = v_row.id;
    return query select false, null::uuid, null::text, 'invalid_code'::text;
    return;
  end if;

  update public.b2b_email_otp_challenges
  set attempt_count = attempt_count + 1,
      consumed_at = now()
  where id = v_row.id;

  return query select true, v_row.application_id, v_row.normalized_email, null::text;
end;
$$;

revoke all on function public.consume_b2b_email_otp_challenge_v1(uuid,text) from public, anon, authenticated;
grant execute on function public.consume_b2b_email_otp_challenge_v1(uuid,text) to service_role;

create or replace function public.activate_approved_b2b_access_by_verified_email_v1(
  p_application_id uuid,
  p_auth_user_id uuid,
  p_verified_email text
)
returns table (
  application_id uuid,
  activated boolean,
  company_id uuid,
  already_active boolean
)
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_app public.b2b_applications%rowtype;
  v_auth_phone text;
  v_auth_email text;
  v_app_email text;
  v_verified_email text;
  v_app_mobile text;
  v_auth_mobile text;
  v_existing_role text;
  v_existing_company uuid;
  v_collision_count integer;
begin
  if p_application_id is null or p_auth_user_id is null then
    raise exception 'VALIDATION_FAILED: application and auth user are required' using errcode = '22023';
  end if;

  v_verified_email := lower(btrim(coalesce(p_verified_email, '')));
  if v_verified_email = '' or position('@' in v_verified_email) <= 1 then
    raise exception 'VALIDATION_FAILED: verified email is invalid' using errcode = '22023';
  end if;

  if public.is_internal_staff(p_auth_user_id) then
    raise exception 'STAFF_IDENTITY_FORBIDDEN: internal staff cannot be activated as a Buyer'
      using errcode = '42501';
  end if;

  select * into v_app
  from public.b2b_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no B2B application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  if v_app.status <> 'approved' or v_app.resolved_company_id is null then
    raise exception 'APPLICATION_NOT_APPROVED: verified email activation requires an approved resolved application'
      using errcode = 'P0001';
  end if;

  v_app_email := lower(btrim(coalesce(v_app.contact_email, '')));
  if v_app_email = '' or v_app_email <> v_verified_email then
    raise exception 'VERIFIED_EMAIL_MISMATCH: verified email does not match the approved application'
      using errcode = '42501';
  end if;

  if v_app.user_id is not null then
    if v_app.user_id <> p_auth_user_id then
      raise exception 'APPLICATION_ALREADY_CLAIMED: approved application belongs to another identity'
        using errcode = '42501';
    end if;
    return query select v_app.id, false, v_app.resolved_company_id, true;
    return;
  end if;

  select u.phone, u.email
  into v_auth_phone, v_auth_email
  from auth.users u
  where u.id = p_auth_user_id;

  if not found then
    raise exception 'AUTH_IDENTITY_NOT_FOUND: canonical Auth identity is missing'
      using errcode = 'P0002';
  end if;

  v_app_mobile := public.normalize_b2b_access_mobile_v2(coalesce(v_app.mobile_number, v_app.contact_phone, ''));
  v_auth_mobile := public.normalize_b2b_access_mobile_v2(coalesce(v_auth_phone, ''));
  if v_app_mobile is null or v_auth_mobile is null or v_app_mobile <> v_auth_mobile then
    raise exception 'CANONICAL_PHONE_MISMATCH: Auth phone does not match the approved application'
      using errcode = '42501';
  end if;

  select count(*)::integer into v_collision_count
  from public.users u
  where u.id <> p_auth_user_id
    and u.deleted_at is null
    and (
      public.normalize_b2b_access_mobile_v2(coalesce(u.phone, '')) = v_app_mobile
      or public.normalize_b2b_access_mobile_v2(coalesce(u.mobile_number, '')) = v_app_mobile
      or exists (
        select 1
        from unnest(coalesce(u.secondary_phones, array[]::text[])) p(phone)
        where public.normalize_b2b_access_mobile_v2(coalesce(p.phone, '')) = v_app_mobile
      )
    );

  if v_collision_count <> 0 then
    raise exception 'PHONE_IDENTITY_COLLISION: another public identity already owns the approved phone'
      using errcode = '23505';
  end if;

  select upper(coalesce(u.role, '')), u.company_id
  into v_existing_role, v_existing_company
  from public.users u
  where u.id = p_auth_user_id
  for update;

  if found and (
    v_existing_role not in ('PENDING', 'PENDING_BUYER', 'B2B_BUYER')
    or (v_existing_company is not null and v_existing_company <> v_app.resolved_company_id)
  ) then
    raise exception 'AUTHORITATIVE_IDENTITY_COLLISION: existing public identity is not a safe Buyer identity'
      using errcode = '42501';
  end if;

  update public.b2b_applications
  set user_id = p_auth_user_id,
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
  set email = coalesce(nullif(v_app.contact_email, ''), email),
      phone = coalesce(nullif(v_app.mobile_number, ''), nullif(v_app.contact_phone, ''), phone),
      role = 'b2b_buyer',
      company_id = v_app.resolved_company_id,
      is_active = true,
      invite_status = 'accepted',
      deleted_at = null
  where id = p_auth_user_id;

  if not found then
    insert into public.users (
      id, email, phone, role, company_id, is_active, invite_status, is_sales_executive
    ) values (
      p_auth_user_id,
      v_app.contact_email,
      coalesce(v_app.mobile_number, v_app.contact_phone),
      'b2b_buyer',
      v_app.resolved_company_id,
      true,
      'accepted',
      false
    );
  end if;

  insert into public.profiles (
    id, company_id, full_name, email, role, mobile_number,
    is_approved, status, price_tier
  ) values (
    p_auth_user_id,
    v_app.resolved_company_id,
    coalesce(nullif(btrim(v_app.contact_person), ''), nullif(btrim(v_app.contact_name), '')),
    v_app.contact_email,
    'b2b_buyer',
    coalesce(v_app.mobile_number, v_app.contact_phone, v_auth_phone),
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
    'B2B_ACCESS_REQUEST_EMAIL_IDENTITY_ACTIVATED',
    'b2b_onboarding',
    'b2b_applications',
    v_app.id::text,
    p_auth_user_id,
    'Server-verified application email activated canonical Buyer identity',
    jsonb_build_object(
      'company_id', v_app.resolved_company_id,
      'user_id', p_auth_user_id,
      'verified_email', v_verified_email,
      'auth_email', v_auth_email
    ),
    'high'
  );

  return query select v_app.id, true, v_app.resolved_company_id, false;
end;
$$;

revoke all on function public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text)
  to service_role;

comment on table public.b2b_email_otp_challenges is
  'Service-only, one-time B2B email OTP challenges. OTPs are stored only as server-keyed MACs and are never returned to clients.';
comment on function public.consume_b2b_email_otp_challenge_v1(uuid,text) is
  'Atomically consumes a service-generated B2B email OTP challenge with expiry, attempt-limit, and replay protection. Service role only.';
comment on function public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text) is
  'Activates exactly one approved B2B application after server-side email OTP verification, preserving the canonical phone-bound Buyer Auth UUID. Service role only.';
