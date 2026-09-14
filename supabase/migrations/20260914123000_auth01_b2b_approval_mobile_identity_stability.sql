-- AUTH-01 follow-up: keep the canonical unfiltered application mobile for
-- post-row-lock identity stability checks while using only a valid 10-15 digit
-- mobile as an advisory-lock / matching key.
--
-- This supersedes the approve_b2b_access_request_v2() definition introduced by
-- 20260914060000_b2b_verified_email_identity_claim.sql without changing its
-- signature, grants, staff authority, lock order, idempotency or activation
-- semantics.

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
  v_email_norm text;
  v_mobile text;
  v_mobile_raw text;
begin
  if v_staff is null or not public.is_internal_staff(v_staff) then
    raise exception 'STAFF_AUTHORITY_REQUIRED: only internal staff may approve a trade application'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_assigned_price_tier), '') = '' then
    raise exception 'VALIDATION_FAILED: assigned_price_tier is required' using errcode = '22023';
  end if;

  -- Preserve the unfiltered normalized value for the later stability check.
  -- Only the filtered value may become an identity lock/match key.
  select
    nullif(lower(btrim(coalesce(a.contact_email, ''))), ''),
    public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, ''))
  into v_email_norm, v_mobile_raw
  from public.b2b_applications a
  where a.id = p_application_id;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  v_mobile := v_mobile_raw;
  if v_mobile is not null and (length(v_mobile) < 10 or length(v_mobile) > 15) then
    v_mobile := null;
  end if;

  -- Keep the deterministic email-then-mobile lock order shared with claim.
  if v_email_norm is not null then
    perform pg_advisory_xact_lock(hashtextextended('b2b_identity_email:' || v_email_norm, 0));
  end if;
  if v_mobile is not null then
    perform pg_advisory_xact_lock(hashtextextended('b2b_identity_mobile:' || v_mobile, 0));
  end if;

  select * into v_app
  from public.b2b_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  -- Compare the locked row to the original canonical value, not the filtered
  -- lock key. A legacy invalid mobile therefore does not look like a mutation.
  if nullif(lower(btrim(coalesce(v_app.contact_email, ''))), '') is distinct from v_email_norm
     or public.normalize_b2b_access_mobile_v2(coalesce(v_app.mobile_number, v_app.contact_phone, '')) is distinct from v_mobile_raw then
    raise exception 'APPLICATION_IDENTITY_CHANGED: retry application approval'
      using errcode = '40001';
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

comment on function public.approve_b2b_access_request_v2(uuid,text,text) is
  'Governed B2B approval. Serializes canonical email/mobile identity with Buyer claim before making an unclaimed application approved; post-lock stability uses the unfiltered canonical mobile.';
