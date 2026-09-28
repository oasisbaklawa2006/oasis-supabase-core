-- AUTH-01 production regression repair:
-- A provider-confirmed phone/email may match exactly one approved company even
-- when the canonical approved application is already bound to an older Auth
-- identity (for example, a legacy email-auth Buyer). In that case the verified
-- current Auth UUID must become an active Buyer member of the same company
-- without stealing or rewriting the existing application binding.
--
-- Invariants:
--   * authenticated, provider-confirmed identifier required
--   * active internal staff are excluded
--   * exactly one approved resolved company may match the verified identity
--   * existing application user_id is never overwritten when non-null
--   * current user cannot be moved from another company
--   * unclaimed applications still bind to the current Auth UUID
--   * membership/profile activation is idempotent and audited

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
  v_company_ids uuid[];
  v_target_company_id uuid;
  v_app public.b2b_applications%rowtype;
  v_existing_company_id uuid;
  v_existing_role text;
  v_existing_active boolean;
  v_was_active_buyer boolean := false;
  v_application_claimed boolean := false;
  v_membership_activated boolean := false;
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

  if v_auth_phone is not null and v_auth_phone_confirmed_at is not null then
    v_mobile := public.normalize_b2b_access_mobile_v2(v_auth_phone);
    if v_mobile is null or length(v_mobile) < 10 or length(v_mobile) > 15 then
      v_auth_phone := null;
      v_mobile := null;
    end if;
  else
    v_auth_phone := null;
    v_mobile := null;
  end if;

  if v_auth_email is not null and v_auth_email_confirmed_at is not null then
    v_email_norm := nullif(lower(btrim(v_auth_email)), '');
    v_auth_email := v_email_norm;
  else
    v_auth_email := null;
    v_email_norm := null;
  end if;

  if v_mobile is null and v_email_norm is null then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  -- Serialize against approval using the same canonical identity locks.
  if v_email_norm is not null then
    perform pg_advisory_xact_lock(hashtextextended('b2b_identity_email:' || v_email_norm, 0));
  end if;
  if v_mobile is not null then
    perform pg_advisory_xact_lock(hashtextextended('b2b_identity_mobile:' || v_mobile, 0));
  end if;

  -- Company authority is the safety boundary. Historical duplicate application
  -- rows are tolerated only when every complete approved match resolves to the
  -- same company. Incomplete approved rows do not grant authority.
  select array_agg(distinct candidate.resolved_company_id order by candidate.resolved_company_id)
  into v_company_ids
  from (
    select a.resolved_company_id
    from public.b2b_applications a
    where a.status = 'approved'
      and a.resolved_company_id is not null
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

  if coalesce(cardinality(v_company_ids), 0) = 0 then
    return query select null::uuid, false, null::uuid, false;
    return;
  end if;

  if cardinality(v_company_ids) <> 1 then
    raise exception 'AMBIGUOUS_APPROVED_APPLICATION: verified Buyer identity matches more than one approved company'
      using errcode = 'P0001';
  end if;

  v_target_company_id := v_company_ids[1];

  -- Prefer an existing binding to this Auth UUID, then an unclaimed application,
  -- then the newest legacy-bound application. A legacy binding is preserved.
  select a.*
  into v_app
  from public.b2b_applications a
  where a.status = 'approved'
    and a.resolved_company_id = v_target_company_id
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
  order by
    case when a.user_id = v_uid then 0 when a.user_id is null then 1 else 2 end,
    a.reviewed_at desc nulls last,
    a.created_at desc nulls last,
    a.id
  limit 1
  for update;

  if not found
     or v_app.status is distinct from 'approved'
     or v_app.resolved_company_id is distinct from v_target_company_id
     or not (
       (v_mobile is not null and public.normalize_b2b_access_mobile_v2(coalesce(v_app.mobile_number, v_app.contact_phone, '')) = v_mobile)
       or
       (v_email_norm is not null and nullif(lower(btrim(coalesce(v_app.contact_email, ''))), '') = v_email_norm)
     ) then
    raise exception 'APPLICATION_IDENTITY_CHANGED: retry Buyer identity claim'
      using errcode = '40001';
  end if;

  -- Lock the current membership row before any authority change. A verified
  -- identity may join the approved company, but may never be silently moved
  -- away from another existing company.
  select u.company_id, u.role, u.is_active
  into v_existing_company_id, v_existing_role, v_existing_active
  from public.users u
  where u.id = v_uid
  for update;

  if found then
    if v_existing_company_id is not null
       and v_existing_company_id is distinct from v_target_company_id then
      raise exception 'IDENTITY_COMPANY_CONFLICT: verified identity is already bound to another company'
        using errcode = 'P0001';
    end if;

    v_was_active_buyer := coalesce(v_existing_active, false)
      and v_existing_company_id = v_target_company_id
      and upper(coalesce(v_existing_role, '')) in (
        'B2B_BUYER','SPECIAL_BUYER','HORECA_BUYER','WHOLESALE_BUYER',
        'BULK_BUYER','BUYER','CLIENT','CUSTOMER_USER'
      );
  end if;

  if v_app.user_id is null then
    update public.b2b_applications
    set user_id = v_uid,
        updated_at = now()
    where id = v_app.id
      and user_id is null;

    if not found then
      raise exception 'APPLICATION_ALREADY_CLAIMED: approved application was claimed concurrently'
        using errcode = '40001';
    end if;
    v_application_claimed := true;
  elsif v_app.user_id = v_uid then
    -- Already bound to this Auth UUID. Do not return early: historical rows may
    -- be application-bound while the current public membership is still pending.
    v_application_claimed := false;
  else
    -- Legacy email/mobile split identity. Preserve the existing application
    -- owner; the verified current Auth UUID receives company membership only.
    v_application_claimed := false;
  end if;

  update public.companies
  set status = 'active',
      price_tier = coalesce(v_app.assigned_price_tier, price_tier)
  where id = v_target_company_id;

  perform set_config('oasis.staff_authority', 'governed', true);

  update public.users
  set role = 'b2b_buyer',
      company_id = v_target_company_id,
      is_active = true,
      invite_status = 'accepted',
      email = coalesce(email, v_auth_email),
      phone = coalesce(phone, v_auth_phone)
  where id = v_uid;

  if not found then
    insert into public.users (id, email, phone, role, company_id, is_active, invite_status)
    values (v_uid, v_auth_email, v_auth_phone, 'b2b_buyer', v_target_company_id, true, 'accepted');
  end if;

  insert into public.profiles (
    id, company_id, full_name, email, role, mobile_number,
    is_approved, status, price_tier
  ) values (
    v_uid,
    v_target_company_id,
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

  v_membership_activated := not v_was_active_buyer;

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
  ) values (
    'B2B_ACCESS_REQUEST_IDENTITY_CLAIMED',
    'b2b_onboarding',
    'b2b_applications',
    v_app.id::text,
    v_uid,
    case
      when v_application_claimed then 'Provider-confirmed Buyer identifier claimed unbound approved B2B access request'
      when v_membership_activated then 'Provider-confirmed Buyer identifier activated membership for legacy-bound approved B2B access request'
      else 'Provider-confirmed Buyer identifier replayed existing approved company membership'
    end,
    jsonb_build_object(
      'company_id', v_target_company_id,
      'user_id', v_uid,
      'verified_mobile_present', (v_mobile is not null),
      'verified_email_present', (v_email_norm is not null),
      'application_claimed', v_application_claimed,
      'application_binding_preserved', (v_app.user_id is not null and v_app.user_id <> v_uid),
      'membership_activated', v_membership_activated,
      'prior_application_user_id_present', (v_app.user_id is not null)
    ),
    'high'
  );

  return query
  select
    v_app.id,
    (v_application_claimed or v_membership_activated),
    v_target_company_id,
    v_was_active_buyer;
end;
$$;

revoke all on function public.claim_approved_b2b_access_request_v2() from public, anon;
grant execute on function public.claim_approved_b2b_access_request_v2() to authenticated, service_role;

comment on function public.claim_approved_b2b_access_request_v2() is
  'Activates exactly one approved B2B company from provider-confirmed Auth phone/email. Existing application bindings are preserved; legacy split identities receive membership without stealing application ownership; ambiguous companies fail closed.';
