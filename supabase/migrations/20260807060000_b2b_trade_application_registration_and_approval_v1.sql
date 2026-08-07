-- Oasis Baklawa Expo — Tranche A: governed B2B buyer registration and
-- internal approval contract.
--
-- Identity chain used (matches the existing buyer_product_prices_v1() /
-- customer_order_status_v1() / customer_order_items_v1() contract family):
--   auth.users -> public.profiles (company_id, is_approved, role, status)
--                    -> public.companies
--
-- Architecture findings that drove this migration:
--
--   1. No trigger on auth.users ever populates public.profiles. The only
--      auth-user trigger (handle_new_user) writes to the legacy
--      public.users table, never public.profiles. So nothing today creates
--      the profiles row the customer _v1 contracts actually read.
--
--   2. The existing "approval path" (trg_activate_company_on_approval /
--      trg_link_buyer_on_application_approval, hardened in
--      20260807053000) writes the approved buyer into public.users, not
--      public.profiles. buyer_product_prices_v1() reads only
--      public.profiles (p.is_approved, p.company_id). So even a
--      successful legacy approval never actually grants buyer access under
--      the current customer _v1 contracts — that path is dead for this
--      purpose. There is no existing governed RPC approval surface; Central
--      READ-ONLY has no b2b_applications/profiles-approval RPC either
--      (direct-table UPDATE only, itself under-guarded — see below). This
--      migration therefore implements the minimum staff-only versioned
--      approval RPC, per the Tranche A brief.
--
--   3. Two sibling permissive-RLS gaps sit directly on the objects this
--      tranche governs and are closed here as part of the same "audit every
--      policy affected by the tranche" requirement, not as scope creep:
--        a. companies: "OASIS_AUTH_INSERT_BYPASS" (authenticated, WITH
--           CHECK true) let any authenticated caller INSERT a companies row
--           with an arbitrary status/credit_limit/payment_terms/price_tier
--           — full company-takeover fields, no predicate at all.
--        b. profiles: "Users insert own profile" (authenticated, WITH
--           CHECK id = auth.uid()) checked only the row's id — a caller
--           could INSERT their own profile with role='ADMIN' (or any
--           is_staff_role value), and enforce_profile_approval_for_staff
--           (BEFORE INSERT) would then auto-set is_approved=true,
--           status='approved' for that self-declared staff role. The
--           existing prevent_profile_privilege_escalation guard only fires
--           BEFORE UPDATE, so it never covered this INSERT path.
--        c. profiles: on the UPDATE side, prevent_profile_privilege_escalation
--           itself (the existing BEFORE UPDATE guard) resets role/is_approved/
--           status/price_tier back to OLD for non-staff callers, but never
--           covered company_id or credit_limit. Combined with "Users update
--           own profile" (id = auth.uid(), no column restriction), any
--           authenticated buyer could UPDATE their own profiles row and
--           attach themselves to an arbitrary company by guessing/
--           enumerating its id — found live by this tranche's own exploit
--           regression test. Fixed by extending the existing guard function
--           rather than adding a second one.
--
--   4. b2b_applications has no company_id column; the legacy trigger
--      matched companies by business_name text only (weak/fuzzy, and
--      client-controlled). This migration adds a server-populated
--      resolved_company_id column and resolves/dedups companies by
--      normalized GSTIN under an advisory lock, so the approval RPC never
--      has to re-guess the company by name.
--
-- Known limitation carried forward (not fixed here, out of Tranche A
-- scope): uq_b2b_applications_email_mobile has no status filter, so a
-- rejected applicant can never resubmit with the same email+mobile. Noted
-- in the PR as a follow-up.

-- ══════════════════════════════════════════════════════════════════════
-- 1. Schema: server-resolved company linkage + dedup/idempotency indexes
-- ══════════════════════════════════════════════════════════════════════

alter table public.b2b_applications
  add column if not exists resolved_company_id uuid references public.companies(id);

comment on column public.b2b_applications.resolved_company_id is
  'Server-resolved company match/creation from submit_b2b_trade_application_v1. Never client-supplied.';

-- One pending application per applicant — the primary idempotency guard
-- for double-tap / retry submission. A retried submission is detected by
-- the RPC itself (short-circuits to the existing pending row) before this
-- index is ever the thing that fires, but the index makes the invariant
-- true under real concurrency (two simultaneous first-time submissions).
create unique index if not exists uq_b2b_applications_one_pending_per_user
  on public.b2b_applications (user_id)
  where status = 'pending' and user_id is not null;

-- Normalized-GSTIN dedup for companies. Without this, concurrent
-- submissions with the same GSTIN (whitespace/case variants included)
-- could create two companies rows for the same real business; the RPC's
-- advisory lock plus this constraint make that impossible even under
-- concurrent retries.
create unique index if not exists uq_companies_gst_number_normalized
  on public.companies (upper(regexp_replace(gst_number, '\s', '', 'g')))
  where gst_number is not null and btrim(gst_number) <> '';

-- ══════════════════════════════════════════════════════════════════════
-- 2. RLS hardening: sibling permissive-INSERT gaps on companies/profiles
-- ══════════════════════════════════════════════════════════════════════

-- companies: remove the unrestricted self-serve INSERT bypass outright.
-- Company creation for buyer registration now happens exclusively inside
-- submit_b2b_trade_application_v1 (SECURITY DEFINER, runs as owner, not
-- subject to this policy). No legitimate buyer-facing flow needs direct
-- client INSERT into companies with caller-controlled status/credit/price
-- fields; "Admins manage companies" already covers the legitimate staff
-- case.
drop policy if exists "OASIS_AUTH_INSERT_BYPASS" on public.companies;

-- profiles: applicant self-insert must land in the same safe state as a
-- fresh registration (pending_buyer / not approved / no company / no
-- price tier / no credit), matching the b2b_applications hardening
-- pattern from 20260807053000 (force every privileged field to its safe
-- default at insert time, RLS layer).
drop policy if exists "Users insert own profile" on public.profiles;

create policy "Users insert own profile"
  on public.profiles
  for insert
  to authenticated
  with check (
    id = auth.uid()
    and coalesce(role, 'pending_buyer') = 'pending_buyer'
    and is_approved is not true
    and coalesce(status, 'pending') = 'pending'
    and company_id is null
    and price_tier is null
    and coalesce(credit_limit, 0) = 0
  );

-- profiles: trigger-level defense in depth for the same INSERT path (so a
-- future loosening of the RLS policy above does not reopen self-declared
-- staff/approved/company-linked profiles). Mirrors
-- prevent_profile_privilege_escalation, which only ever covered UPDATE.
create or replace function public.prevent_profile_insert_privilege_escalation()
  returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
begin
  if auth.role() = 'service_role' or public.is_internal_staff(auth.uid()) then
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

drop trigger if exists trg_prevent_profile_insert_priv_esc on public.profiles;
create trigger trg_prevent_profile_insert_priv_esc
  before insert on public.profiles
  for each row
  execute function public.prevent_profile_insert_privilege_escalation();

revoke all on function public.prevent_profile_insert_privilege_escalation() from public, anon, authenticated;
grant all on function public.prevent_profile_insert_privilege_escalation() to service_role;

-- profiles: the pre-existing prevent_profile_privilege_escalation UPDATE
-- guard (20260723161256 baseline) resets role/is_approved/status/price_tier
-- back to OLD for non-staff callers, but never covered company_id or
-- credit_limit. Combined with "Users update own profile" (id = auth.uid(),
-- no column restriction), any authenticated buyer could attach themselves
-- to an arbitrary company by UPDATE-ing their own profiles row with a
-- guessed/enumerated company_id — the exact cross-company-attachment and
-- profile-elevation path this tranche is required to close. Extended here
-- rather than reimplemented, to keep exactly one guard function for this
-- trigger.
create or replace function public.prevent_profile_privilege_escalation()
  returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
begin
  if public.is_internal_staff(auth.uid()) then
    return new;
  end if;

  -- Non-staff cannot change sensitive fields
  if new.role is distinct from old.role then
    new.role := old.role;
  end if;
  if to_jsonb(new) ? 'is_approved' and (to_jsonb(new)->>'is_approved') is distinct from (to_jsonb(old)->>'is_approved') then
    new := jsonb_populate_record(new, jsonb_build_object('is_approved', to_jsonb(old)->'is_approved'));
  end if;
  if to_jsonb(new) ? 'status' and (to_jsonb(new)->>'status') is distinct from (to_jsonb(old)->>'status') then
    new := jsonb_populate_record(new, jsonb_build_object('status', to_jsonb(old)->'status'));
  end if;
  if to_jsonb(new) ? 'price_tier' and (to_jsonb(new)->>'price_tier') is distinct from (to_jsonb(old)->>'price_tier') then
    new := jsonb_populate_record(new, jsonb_build_object('price_tier', to_jsonb(old)->'price_tier'));
  end if;
  if new.company_id is distinct from old.company_id then
    new.company_id := old.company_id;
  end if;
  if to_jsonb(new) ? 'credit_limit' and (to_jsonb(new)->>'credit_limit') is distinct from (to_jsonb(old)->>'credit_limit') then
    new := jsonb_populate_record(new, jsonb_build_object('credit_limit', to_jsonb(old)->'credit_limit'));
  end if;

  return new;
end;
$$;

-- b2b_applications: the existing "Staff manage applications" UPDATE policy
-- (is_internal_staff-gated, unchanged in scope/predicate otherwise) let any
-- staff member set reviewed_by to an arbitrary UUID when moving an
-- application to approved/rejected via a direct PostgREST UPDATE — the
-- client, not the server, controlled reviewer attribution on that path.
-- submit/approve/reject_b2b_trade_application_v1 below are SECURITY
-- DEFINER and run as table owner, so they are unaffected by this policy;
-- this closes the parallel legacy direct-table path so reviewer identity
-- cannot be spoofed there either.
drop policy if exists "Staff manage applications" on public.b2b_applications;

create policy "Staff manage applications"
  on public.b2b_applications
  for update
  to authenticated
  using (public.is_internal_staff(auth.uid()))
  with check (
    public.is_internal_staff(auth.uid())
    and (
      status not in ('approved', 'rejected')
      or (reviewed_by = auth.uid() and reviewed_at is not null)
    )
  );

-- ══════════════════════════════════════════════════════════════════════
-- 3. submit_b2b_trade_application_v1: customer registration RPC
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.submit_b2b_trade_application_v1(
  p_business_name text,
  p_trade_name text default null,
  p_business_type text default null,
  p_gst_number text default null,
  p_expected_volume text default null,
  p_contact_name text default null,
  p_contact_person text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_mobile_number text default null,
  p_registered_address text default null,
  p_city text default null,
  p_state text default null,
  p_pincode text default null,
  p_gst_certificate_path text default null,
  p_business_proof_path text default null,
  p_current_brands text default null,
  p_preferred_dispatch text default null,
  p_preferred_dispatch_other_name text default null,
  p_trade_declaration boolean default false,
  p_data_consent boolean default false
)
returns table (
  application_id uuid,
  application_status text,
  company_id uuid,
  is_duplicate_submission boolean
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_gst_norm text;
  v_company_id uuid;
  v_existing_app_id uuid;
  v_existing_company_id uuid;
  v_app_id uuid;
begin
  -- Fail closed: no session, no application. Never trust a client-supplied
  -- user/profile/company identifier — identity is derived exclusively from
  -- auth.uid().
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required to submit a trade application'
      using errcode = '28000';
  end if;

  if coalesce(btrim(p_business_name), '') = '' then
    raise exception 'VALIDATION_FAILED: business_name is required';
  end if;

  if not coalesce(p_trade_declaration, false) or not coalesce(p_data_consent, false) then
    raise exception 'VALIDATION_FAILED: trade_declaration and data_consent must both be accepted';
  end if;

  -- Idempotency: a retried submission (double-tap, mobile retry, network
  -- retry, RPC retry) for a caller who already has a pending application
  -- returns that same application rather than creating a duplicate.
  select id, resolved_company_id into v_existing_app_id, v_existing_company_id
  from public.b2b_applications
  where user_id = v_uid and status = 'pending'
  limit 1;

  if v_existing_app_id is not null then
    return query select v_existing_app_id, 'pending'::text, v_existing_company_id, true;
    return;
  end if;

  v_gst_norm := nullif(upper(regexp_replace(coalesce(p_gst_number, ''), '\s', '', 'g')), '');

  if v_gst_norm is not null then
    -- Serialize concurrent submissions for the same normalized GSTIN so the
    -- select-then-insert below cannot race into two companies rows; the
    -- unique index added above is the second, independent layer.
    perform pg_advisory_xact_lock(hashtextextended('b2b_company_gst:' || v_gst_norm, 0));

    select id into v_company_id
    from public.companies
    where gst_number is not null
      and upper(regexp_replace(gst_number, '\s', '', 'g')) = v_gst_norm
    limit 1;
  end if;

  if v_company_id is null then
    begin
      insert into public.companies (business_name, gst_number, phone, registered_address, status)
      values (btrim(p_business_name), p_gst_number, p_mobile_number, p_registered_address, 'pending')
      returning id into v_company_id;
    exception when unique_violation then
      -- Lost a race despite the advisory lock (e.g. a concurrent submission
      -- with no GSTIN normalizing to the same key via a different path) —
      -- fall back to the row that won.
      select id into v_company_id
      from public.companies
      where gst_number is not null
        and upper(regexp_replace(gst_number, '\s', '', 'g')) = v_gst_norm
      limit 1;

      if v_company_id is null then
        raise;
      end if;
    end;
  end if;

  begin
    insert into public.b2b_applications (
      business_name, trade_name, business_type, gst_number, expected_volume,
      contact_name, contact_person, contact_email, contact_phone, mobile_number,
      registered_address, city, state, pincode,
      gst_certificate_path, business_proof_path, current_brands,
      preferred_dispatch, preferred_dispatch_other_name,
      trade_declaration, data_consent,
      user_id, resolved_company_id, status
    ) values (
      btrim(p_business_name), p_trade_name, p_business_type, p_gst_number, p_expected_volume,
      p_contact_name, p_contact_person, p_contact_email, p_contact_phone, p_mobile_number,
      p_registered_address, p_city, p_state, p_pincode,
      p_gst_certificate_path, p_business_proof_path, p_current_brands,
      p_preferred_dispatch, p_preferred_dispatch_other_name,
      true, true,
      v_uid, v_company_id, 'pending'
    )
    returning id into v_app_id;
  exception when unique_violation then
    -- Concurrent identical retry racing past the pending-application
    -- short-circuit above, or the legacy email+mobile uniqueness guard.
    select id into v_existing_app_id
    from public.b2b_applications
    where user_id = v_uid and status = 'pending'
    limit 1;

    if v_existing_app_id is not null then
      return query select v_existing_app_id, 'pending'::text, v_company_id, true;
      return;
    end if;

    raise exception 'DUPLICATE_APPLICATION: an application with this email/mobile number already exists'
      using errcode = '23505';
  end;

  -- Applicant profile: created in the same safe pending state RLS/triggers
  -- above enforce for a direct client INSERT. Never touches an
  -- already-approved or staff profile (the WHERE guard below), and never
  -- sets company_id/role/is_approved/price_tier/credit_limit from caller
  -- input — submission must never activate the company.
  insert into public.profiles (id, company_id, full_name, email, role, mobile_number, is_approved, status)
  values (
    v_uid, null, coalesce(nullif(btrim(p_contact_person), ''), nullif(btrim(p_contact_name), '')),
    p_contact_email, 'pending_buyer', p_mobile_number, false, 'pending'
  )
  on conflict (id) do update set
    full_name = coalesce(public.profiles.full_name, excluded.full_name),
    email = coalesce(public.profiles.email, excluded.email)
  where public.profiles.is_approved is not true;

  return query select v_app_id, 'pending'::text, v_company_id, false;
exception
  when unique_violation then
    if position('unique_mobile_number' in sqlerrm) > 0
      or position('unique_phone' in sqlerrm) > 0
      or position('unique_phone_number' in sqlerrm) > 0 then
      raise exception 'MOBILE_NUMBER_ALREADY_REGISTERED: this mobile number is already linked to another account'
        using errcode = '23505';
    end if;
    raise;
end;
$$;

comment on function public.submit_b2b_trade_application_v1(
  text, text, text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, boolean, boolean
) is
  'Governed B2B buyer registration contract (Tranche A). Identity derived exclusively from auth.uid(); caller cannot control role/approval/company/price/credit fields. Fails closed without an authenticated session.';

revoke all on function public.submit_b2b_trade_application_v1(
  text, text, text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, boolean, boolean
) from public, anon;
grant execute on function public.submit_b2b_trade_application_v1(
  text, text, text, text, text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, boolean, boolean
) to authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- 4. approve_b2b_trade_application_v1 / reject_b2b_trade_application_v1:
--    staff-only internal approval RPCs
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.approve_b2b_trade_application_v1(
  p_application_id uuid,
  p_assigned_price_tier text default null,
  p_admin_notes text default null
)
returns table (
  application_id uuid,
  application_status text,
  company_id uuid
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := auth.uid();
  v_app public.b2b_applications%rowtype;
begin
  if v_staff is null or not public.is_internal_staff(v_staff) then
    raise exception 'STAFF_AUTHORITY_REQUIRED: only internal staff may approve a trade application'
      using errcode = '42501';
  end if;

  select * into v_app from public.b2b_applications where id = p_application_id for update;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  -- Safe against repeated invocation: an already-approved application is a
  -- no-op returning its current state, not an error or a re-application of
  -- side effects.
  if v_app.status = 'approved' then
    return query select v_app.id, v_app.status, v_app.resolved_company_id;
    return;
  end if;

  if v_app.status <> 'pending' then
    raise exception 'APPLICATION_NOT_PENDING: application % is in status %, only a pending application can be approved',
      p_application_id, v_app.status
      using errcode = 'P0001';
  end if;

  if v_app.resolved_company_id is null or v_app.user_id is null then
    raise exception 'APPLICATION_INCOMPLETE: application % is missing its resolved company or applicant identity',
      p_application_id
      using errcode = 'P0001';
  end if;

  update public.b2b_applications
  set status = 'approved',
      reviewed_by = v_staff,
      reviewed_at = now(),
      assigned_price_tier = coalesce(p_assigned_price_tier, assigned_price_tier),
      admin_notes = coalesce(p_admin_notes, admin_notes),
      rejection_reason = null
  where id = p_application_id;

  update public.companies
  set status = 'active',
      price_tier = coalesce(p_assigned_price_tier, price_tier)
  where id = v_app.resolved_company_id;

  update public.profiles
  set company_id = v_app.resolved_company_id,
      role = 'b2b_buyer',
      is_approved = true,
      status = 'approved',
      price_tier = coalesce(p_assigned_price_tier, price_tier)
  where id = v_app.user_id;

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
  ) values (
    'B2B_APPLICATION_APPROVED', 'b2b_onboarding', 'b2b_applications', p_application_id::text, v_staff,
    p_admin_notes,
    jsonb_build_object(
      'company_id', v_app.resolved_company_id,
      'user_id', v_app.user_id,
      'assigned_price_tier', p_assigned_price_tier
    ),
    'high'
  );

  return query select p_application_id, 'approved'::text, v_app.resolved_company_id;
end;
$$;

comment on function public.approve_b2b_trade_application_v1(uuid, text, text) is
  'Staff-only trade application approval (Tranche A). Reviewer identity derived exclusively from auth.uid(); fails closed for non-staff callers; idempotent on an already-approved application.';

revoke all on function public.approve_b2b_trade_application_v1(uuid, text, text) from public, anon, authenticated;
grant execute on function public.approve_b2b_trade_application_v1(uuid, text, text) to authenticated, service_role;

create or replace function public.reject_b2b_trade_application_v1(
  p_application_id uuid,
  p_rejection_reason text
)
returns table (
  application_id uuid,
  application_status text
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := auth.uid();
  v_app public.b2b_applications%rowtype;
begin
  if v_staff is null or not public.is_internal_staff(v_staff) then
    raise exception 'STAFF_AUTHORITY_REQUIRED: only internal staff may reject a trade application'
      using errcode = '42501';
  end if;

  if coalesce(btrim(p_rejection_reason), '') = '' then
    raise exception 'VALIDATION_FAILED: rejection_reason is required';
  end if;

  select * into v_app from public.b2b_applications where id = p_application_id for update;

  if not found then
    raise exception 'APPLICATION_NOT_FOUND: no application with id %', p_application_id
      using errcode = 'P0002';
  end if;

  if v_app.status = 'rejected' then
    return query select v_app.id, v_app.status;
    return;
  end if;

  if v_app.status <> 'pending' then
    raise exception 'APPLICATION_NOT_PENDING: application % is in status %, only a pending application can be rejected',
      p_application_id, v_app.status
      using errcode = 'P0001';
  end if;

  -- Rejection must never activate/link a buyer: only b2b_applications is
  -- touched here, companies/profiles are left exactly as they were
  -- (still pending/unapproved from submission).
  update public.b2b_applications
  set status = 'rejected',
      reviewed_by = v_staff,
      reviewed_at = now(),
      rejection_reason = p_rejection_reason
  where id = p_application_id;

  insert into public.audit_logs (
    action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
  ) values (
    'B2B_APPLICATION_REJECTED', 'b2b_onboarding', 'b2b_applications', p_application_id::text, v_staff,
    p_rejection_reason,
    jsonb_build_object('company_id', v_app.resolved_company_id, 'user_id', v_app.user_id),
    'high'
  );

  return query select p_application_id, 'rejected'::text;
end;
$$;

comment on function public.reject_b2b_trade_application_v1(uuid, text) is
  'Staff-only trade application rejection (Tranche A). Reviewer identity derived exclusively from auth.uid(); never activates a company or links a buyer profile; idempotent on an already-rejected application.';

revoke all on function public.reject_b2b_trade_application_v1(uuid, text) from public, anon, authenticated;
grant execute on function public.reject_b2b_trade_application_v1(uuid, text) to authenticated, service_role;
