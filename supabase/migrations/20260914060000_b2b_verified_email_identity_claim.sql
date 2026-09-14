-- AUTH-01: allow an approved B2B request to be claimed by either the
-- provider-confirmed mobile identity or the provider-confirmed approved email.
--
-- Security invariants:
--   * authenticated session required
--   * internal staff never claim Buyer authority
--   * only confirmed auth.users phone/email identifiers participate
--   * already-bound applications cannot be stolen by another auth.uid()
--   * multiple eligible unclaimed applications fail closed
--   * the existing function signature and grants remain unchanged

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
  v_auth_email text;
  v_auth_email_confirmed_at timestamptz;
  v_mobile text;
  v_email_norm text;
  v_match_ids uuid[];
  v_app public.b2b_applications%rowtype;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: an authenticated session is required' using errcode = '28000';
  end if;

  if public.is_internal_staff(v_uid) then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  select u.phone, u.phone_confirmed_at, u.email, u.email_confirmed_at
  into v_auth_phone, v_auth_phone_confirmed_at, v_auth_email, v_auth_email_confirmed_at
  from auth.users u
  where u.id = v_uid;

  -- Idempotent replay: an application already bound to this exact Auth user is
  -- authoritative regardless of which confirmed channel was used this time.
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

  if v_auth_phone is not null and v_auth_phone_confirmed_at is not null then
    v_mobile := public.normalize_b2b_access_mobile_v2(v_auth_phone);
    if v_mobile is null or length(v_mobile) < 10 or length(v_mobile) > 15 then
      v_mobile := null;
    end if;
  else
    v_mobile := null;
  end if;

  if v_auth_email is not null and v_auth_email_confirmed_at is not null then
    v_email_norm := nullif(lower(btrim(v_auth_email)), '');
  else
    v_email_norm := null;
  end if;

  if v_mobile is null and v_email_norm is null then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  select array_agg(candidate.id order by candidate.reviewed_at desc nulls last, candidate.created_at desc nulls last)
  into v_match_ids
  from (
    select distinct a.id, a.reviewed_at, a.created_at
    from public.b2b_applications a
    where a.status = 'approved'
      and a.user_id is null
      and (
        (
          v_mobile is not null
          and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
        )
        or
        (
          v_email_norm is not null
          and nullif(lower(btrim(coalesce(a.contact_email, ''))), '') = v_email_norm
        )
      )
  ) candidate;

  if coalesce(cardinality(v_match_ids), 0) = 0 then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  if cardinality(v_match_ids) <> 1 then
    raise exception 'AMBIGUOUS_APPROVED_APPLICATION: more than one approved application matches the verified Buyer identity'
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
      invite_status = 'accepted',
      email = coalesce(email, v_auth_email),
      phone = coalesce(phone, v_auth_phone)
  where id = v_uid;

  if not found then
    insert into public.users (id, email, phone, role, company_id, is_active, invite_status)
    values (v_uid, v_auth_email, v_auth_phone, 'b2b_buyer', v_app.resolved_company_id, true, 'accepted');
  end if;

  insert into public.profiles (
    id, company_id, full_name, email, role, mobile_number,
    is_approved, status, price_tier
  ) values (
    v_uid,
    v_app.resolved_company_id,
    coalesce(nullif(btrim(v_app.contact_person), ''), nullif(btrim(v_app.contact_name), '')),
    coalesce(v_app.contact_email, v_auth_email),
    'b2b_buyer',
    coalesce(v_auth_phone, v_app.mobile_number, v_app.contact_phone),
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
    'Provider-confirmed Buyer identifier claimed approved B2B access request',
    jsonb_build_object(
      'company_id', v_app.resolved_company_id,
      'user_id', v_uid,
      'verified_mobile_present', (v_mobile is not null),
      'verified_email_present', (v_email_norm is not null)
    ),
    'high'
  );

  return query select v_app.id, true, v_app.resolved_company_id, false;
end;
$$;

revoke all on function public.claim_approved_b2b_access_request_v2() from public, anon;
grant execute on function public.claim_approved_b2b_access_request_v2() to authenticated, service_role;

comment on function public.claim_approved_b2b_access_request_v2() is
  'Claims exactly one approved, unclaimed B2B application using a provider-confirmed Auth phone or confirmed Auth email. Internal staff are excluded; ambiguous matches fail closed.';
