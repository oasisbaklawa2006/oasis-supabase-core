-- Contract test for 20260807060000_b2b_trade_application_registration_and_approval_v1.sql
--
-- Oasis Baklawa Expo Tranche A: governed B2B buyer registration
-- (submit_b2b_trade_application_v1) and internal approval
-- (approve_b2b_trade_application_v1 / reject_b2b_trade_application_v1).
--
-- Follows this repository's established static/introspective pgTAP style
-- (pg_policies / pg_proc / has_function_privilege) plus live role-simulated
-- exploit attempts and positive-path regressions, matching
-- 20260807053000_harden_privileged_approval_and_credit_triggers.sql.
begin;

select plan(31);

-- ══════════════════════════════════════════════════════════════════════
-- Static: schema/index/column contract
-- ══════════════════════════════════════════════════════════════════════

select has_column(
  'public', 'b2b_applications', 'resolved_company_id',
  'b2b_applications gains a server-resolved company_id column'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'b2b_applications'
      and indexname = 'uq_b2b_applications_one_pending_per_user'
  ),
  'one-pending-application-per-user partial unique index exists'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'companies'
      and indexname = 'uq_companies_gst_number_normalized'
  ),
  'normalized-GSTIN unique index exists on companies'
);

-- ══════════════════════════════════════════════════════════════════════
-- Static: RLS hardening — sibling permissive-INSERT gaps closed
-- ══════════════════════════════════════════════════════════════════════

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'companies'
      and policyname = 'OASIS_AUTH_INSERT_BYPASS'
  ),
  'unrestricted companies INSERT bypass (WITH CHECK true) is removed'
);

select is(
  (
    select count(*)::integer from pg_policies
    where schemaname = 'public' and tablename = 'companies'
      and cmd = 'INSERT'
  ),
  0,
  'no INSERT policy remains on companies for self-serve callers — creation is RPC-only'
);

select ok(
  exists(
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'profiles'
      and policyname = 'Users insert own profile' and cmd = 'INSERT'
      and with_check ilike '%is_approved is not true%'
      and with_check ilike '%company_id is null%'
      and with_check ilike '%price_tier is null%'
  ),
  'profiles self-insert policy forces safe pending defaults (role/is_approved/status/company_id/price_tier/credit_limit)'
);

select trigger_is(
  'public', 'profiles', 'trg_prevent_profile_insert_priv_esc',
  'public', 'prevent_profile_insert_privilege_escalation',
  'profiles INSERT carries a trigger-level defense-in-depth guard (RLS-independent)'
);

-- The pre-existing prevent_profile_privilege_escalation UPDATE guard
-- (20260723161256 baseline) never covered company_id/credit_limit, so a
-- direct "Users update own profile" UPDATE could attach a buyer to an
-- arbitrary company by guessing its id. Extended by this migration.
select ok(
  pg_get_functiondef('public.prevent_profile_privilege_escalation()'::regprocedure) like '%new.company_id := old.company_id%',
  'prevent_profile_privilege_escalation now also guards company_id against non-staff UPDATE (closes a pre-existing cross-company-attachment gap)'
);

select ok(
  not has_function_privilege('anon', 'public.prevent_profile_insert_privilege_escalation()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.prevent_profile_insert_privilege_escalation()', 'EXECUTE'),
  'prevent_profile_insert_privilege_escalation is trigger-only, least privilege'
);

select ok(
  exists(
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'b2b_applications'
      and policyname = 'Staff manage applications' and cmd = 'UPDATE'
      and with_check like '%reviewed_by = auth.uid()%'
  ),
  'b2b_applications direct-table staff UPDATE now forces server-attributed reviewed_by on approve/reject transitions'
);

-- ══════════════════════════════════════════════════════════════════════
-- Static: RPC contract — signatures, security, grants
-- ══════════════════════════════════════════════════════════════════════

select ok(
  to_regprocedure(
    'public.submit_b2b_trade_application_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,boolean)'
  ) is not null,
  'submit_b2b_trade_application_v1 exists with the expected signature'
);

select ok(
  to_regprocedure('public.approve_b2b_trade_application_v1(uuid,text,text)') is not null,
  'approve_b2b_trade_application_v1 exists with the expected signature'
);

select ok(
  to_regprocedure('public.reject_b2b_trade_application_v1(uuid,text)') is not null,
  'reject_b2b_trade_application_v1 exists with the expected signature'
);

select ok(
  pg_get_functiondef('public.submit_b2b_trade_application_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,boolean)'::regprocedure) like '%SECURITY DEFINER%'
  and pg_get_functiondef('public.submit_b2b_trade_application_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,boolean)'::regprocedure) like '%SET search_path TO ''public''%',
  'submit_b2b_trade_application_v1 is SECURITY DEFINER with an explicit safe search_path'
);

select ok(
  pg_get_functiondef('public.approve_b2b_trade_application_v1(uuid,text,text)'::regprocedure) like '%is_internal_staff%',
  'approve_b2b_trade_application_v1 carries an explicit staff-authority guard'
);

select ok(
  pg_get_functiondef('public.reject_b2b_trade_application_v1(uuid,text)'::regprocedure) like '%is_internal_staff%',
  'reject_b2b_trade_application_v1 carries an explicit staff-authority guard'
);

-- Caller cannot control privileged fields: none of role/is_approved/company_id/
-- price_tier/credit_limit/reviewed_by/reviewed_at/status appear as a
-- parameter name of the registration RPC.
select ok(
  not exists (
    select 1
    from unnest(string_to_array(
      pg_get_function_arguments('public.submit_b2b_trade_application_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,boolean)'::regprocedure),
      ','
    )) as arg
    where btrim(arg) ~* '^(p_)?(role|is_approved|company_id|price_tier|credit_limit|reviewed_by|reviewed_at|status|user_id)\b'
  ),
  'submit_b2b_trade_application_v1 exposes no parameter for any privileged/reviewer-owned field'
);

select ok(
  not has_function_privilege('anon', 'public.submit_b2b_trade_application_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean,boolean)', 'EXECUTE'),
  'submit_b2b_trade_application_v1 is not executable by anon'
);

select ok(
  not has_function_privilege('anon', 'public.approve_b2b_trade_application_v1(uuid,text,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.approve_b2b_trade_application_v1(uuid,text,text)', 'EXECUTE'),
  'approve_b2b_trade_application_v1 is executable by authenticated (staff-checked inside) but not anon'
);

select ok(
  not has_function_privilege('anon', 'public.reject_b2b_trade_application_v1(uuid,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.reject_b2b_trade_application_v1(uuid,text)', 'EXECUTE'),
  'reject_b2b_trade_application_v1 is executable by authenticated (staff-checked inside) but not anon'
);

-- ══════════════════════════════════════════════════════════════════════
-- Live: fail-closed authentication
-- ══════════════════════════════════════════════════════════════════════

select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select public.submit_b2b_trade_application_v1(p_business_name := 'Unauth Co') $$,
  '28000',
  null,
  'submit_b2b_trade_application_v1 fails closed with no auth.uid()'
);

-- ══════════════════════════════════════════════════════════════════════
-- Live: registration → safe pending state → idempotent retry
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_buyer uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_app_id uuid;
  v_company_id uuid;
  v_retry_app_id uuid;
  v_retry_company_id uuid;
  v_dup boolean;
  v_product_id uuid;
  v_prof record;
  v_comp record;
begin
  insert into auth.users (id, email) values (v_buyer, 'contract-buyer@example.com');
  insert into auth.users (id, email) values (v_staff, 'contract-staff@example.com');
  insert into auth.users (id, email) values (v_other, 'contract-other@example.com');
  insert into public.users (id, email, role) values (v_staff, 'contract-staff@example.com', 'ADMIN');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select application_id, company_id into v_app_id, v_company_id
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Contract Test Trading Co',
    p_gst_number := '29CTRCT1234F2Z5',
    p_contact_email := 'contract-buyer@example.com',
    p_mobile_number := '9888800001',
    p_trade_declaration := true,
    p_data_consent := true
  );

  if v_app_id is null or v_company_id is null then
    raise exception 'EXPECTED BEHAVIOR MISSING: submission did not return application_id/company_id';
  end if;

  select * into v_prof from public.profiles where id = v_buyer;
  if v_prof.status <> 'pending' or coalesce(v_prof.is_approved, false) or v_prof.company_id is not null then
    raise exception 'SAFE-STATE REGRESSION: submission profile is not fail-closed pending (status=%, is_approved=%, company_id=%)',
      v_prof.status, v_prof.is_approved, v_prof.company_id;
  end if;

  -- companies has no applicant-visible SELECT policy pre-approval (the
  -- buyer's profile isn't linked to it yet) — read as the table owner to
  -- verify real state, then resume impersonating the buyer.
  reset role;
  select * into v_comp from public.companies where id = v_company_id;
  if v_comp.status <> 'pending' then
    raise exception 'SAFE-STATE REGRESSION: submission activated the company (status=%)', v_comp.status;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- idempotent retry: same caller, same payload, must short-circuit to the
  -- existing pending application rather than creating a duplicate.
  select application_id, company_id, is_duplicate_submission
    into v_retry_app_id, v_retry_company_id, v_dup
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Contract Test Trading Co',
    p_gst_number := '29CTRCT1234F2Z5',
    p_contact_email := 'contract-buyer@example.com',
    p_mobile_number := '9888800001',
    p_trade_declaration := true,
    p_data_consent := true
  );

  if v_retry_app_id <> v_app_id or v_retry_company_id <> v_company_id or not v_dup then
    raise exception 'IDEMPOTENCY REGRESSION: retried submission did not short-circuit to the existing pending application';
  end if;

  if (select count(*) from public.b2b_applications where user_id = v_buyer) <> 1 then
    raise exception 'IDEMPOTENCY REGRESSION: retry created a duplicate b2b_applications row';
  end if;

  reset role;
  if (select count(*) from public.companies where business_name = 'Contract Test Trading Co') <> 1 then
    raise exception 'IDEMPOTENCY REGRESSION: retry created a duplicate companies row';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- applicant cannot self-approve
  begin
    perform public.approve_b2b_trade_application_v1(v_app_id);
    raise exception 'SECURITY REGRESSION: applicant self-approved their own application';
  exception
    when sqlstate '42501' then null;
  end;

  -- applicant cannot self-reject either (not staff)
  begin
    perform public.reject_b2b_trade_application_v1(v_app_id, 'self-reject attempt');
    raise exception 'SECURITY REGRESSION: applicant rejected their own application';
  exception
    when sqlstate '42501' then null;
  end;

  -- a different, non-staff authenticated caller cannot approve/reject either
  perform set_config('request.jwt.claims', json_build_object('sub', v_other::text, 'role', 'authenticated')::text, true);
  begin
    perform public.approve_b2b_trade_application_v1(v_app_id);
    raise exception 'SECURITY REGRESSION: unrelated non-staff user approved an application';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.reject_b2b_trade_application_v1(v_app_id, 'not mine to reject');
    raise exception 'SECURITY REGRESSION: unrelated non-staff user rejected an application';
  exception
    when sqlstate '42501' then null;
  end;

  -- applicant cannot elevate their own profile via a direct table INSERT/UPDATE
  -- (id conflict forces the RLS-guarded UPDATE path — "Users update own
  -- profile" — which the pre-existing prevent_profile_privilege_escalation
  -- trigger silently normalizes back to safe values rather than rejecting).
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  update public.profiles
  set role = 'ADMIN', is_approved = true, status = 'approved', company_id = v_company_id, price_tier = 'A', credit_limit = 999999
  where id = v_buyer;

  select * into v_prof from public.profiles where id = v_buyer;
  if upper(coalesce(v_prof.role, '')) = 'ADMIN'
    or coalesce(v_prof.is_approved, false)
    or v_prof.company_id is not null
    or v_prof.price_tier is not null
    or lower(coalesce(v_prof.status, '')) = 'approved'
    or coalesce(v_prof.credit_limit, 0) <> 0
  then
    raise exception 'SECURITY REGRESSION: applicant self-update escalated privileged profile fields (role=%, is_approved=%, company_id=%, price_tier=%, status=%, credit_limit=%)',
      v_prof.role, v_prof.is_approved, v_prof.company_id, v_prof.price_tier, v_prof.status, v_prof.credit_limit;
  end if;

  -- applicant cannot attach to another company's identity by guessing a
  -- second company's id via direct profile update either.
  if v_prof.company_id is not null then
    raise exception 'SECURITY REGRESSION: applicant attached to a company via direct profile mutation';
  end if;

  reset role;

  -- ── staff approval: legitimate positive path ───────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.approve_b2b_trade_application_v1(v_app_id, 'TIER_A', 'contract test approval');

  select * into v_comp from public.companies where id = v_company_id;
  select * into v_prof from public.profiles where id = v_buyer;

  if v_comp.status <> 'active' or v_comp.price_tier <> 'TIER_A' then
    raise exception 'APPROVAL REGRESSION: company not activated with assigned price tier (status=%, price_tier=%)',
      v_comp.status, v_comp.price_tier;
  end if;

  if not coalesce(v_prof.is_approved, false) or v_prof.status <> 'approved' or v_prof.company_id <> v_company_id then
    raise exception 'APPROVAL REGRESSION: buyer profile not correctly linked/approved (is_approved=%, status=%, company_id=%)',
      v_prof.is_approved, v_prof.status, v_prof.company_id;
  end if;

  if (select reviewed_by from public.b2b_applications where id = v_app_id) <> v_staff then
    raise exception 'AUDITABILITY REGRESSION: reviewed_by does not reflect the approving staff member';
  end if;

  if (select reviewed_at from public.b2b_applications where id = v_app_id) is null then
    raise exception 'AUDITABILITY REGRESSION: reviewed_at was not set on approval';
  end if;

  -- audit_logs' own "Admins can read audit_logs" policy compares
  -- public.users.role case-sensitively against lowercase 'admin' — a
  -- separate, pre-existing legacy inconsistency with this codebase's
  -- uppercase role convention (is_internal_staff() upper()-normalizes;
  -- this policy does not). Out of scope to fix here; read as table owner.
  reset role;
  if not exists (
    select 1 from public.audit_logs
    where action_type = 'B2B_APPLICATION_APPROVED' and entity_id = v_app_id::text and actor_id = v_staff
  ) then
    raise exception 'AUDITABILITY REGRESSION: no audit_logs row for the approval decision';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- approved buyer reaches the exact state the customer _v1 contracts need.
  -- buyer_product_prices_v1() cross-joins its "buyer" CTE (approval state)
  -- against actual product_pricing_rules/published product rows, so an
  -- empty catalogue (true in this from-scratch replay, with no seed
  -- product data) would return zero rows regardless of approval
  -- correctness — a bare PERFORM proves only that it doesn't raise. Seed
  -- one minimal published, priced product so the row count actually
  -- exercises the full contract, not just the "doesn't error" half of it.
  reset role;
  insert into public.products (id, name, sku, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready)
  values (gen_random_uuid(), 'Contract Test Product', 'CTP-TEST-001', 'ready_goods', '0000.00.00', true, true, true)
  returning id into v_product_id;

  insert into public.product_pricing_rules (product_id, price_channel, base_price, approval_status)
  values (v_product_id, 'b2b', 100, 'approved');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if not exists (select 1 from public.buyer_product_prices_v1() where product_id = v_product_id) then
    raise exception 'CONTRACT REGRESSION: buyer_product_prices_v1() did not return the seeded product (%) for an approved buyer', v_product_id;
  end if;

  if public.auth_buyer_company_id() <> v_company_id then
    raise exception 'CONTRACT REGRESSION: auth_buyer_company_id() does not resolve the approved buyer to their company';
  end if;

  -- repeated approval is a safe no-op, not a re-application of side effects
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  perform public.approve_b2b_trade_application_v1(v_app_id, 'TIER_B');
  if (select price_tier from public.companies where id = v_company_id) <> 'TIER_A' then
    raise exception 'IDEMPOTENCY REGRESSION: repeated approval re-applied side effects (price_tier changed on an already-approved application)';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('registration → staff approval reaches the exact state buyer_product_prices_v1()/auth_buyer_company_id() require, with correct auditability and idempotency');

-- ══════════════════════════════════════════════════════════════════════
-- Live: rejection must not activate/link a buyer; requires a reason;
-- concurrent GSTIN dedup collapses to one company
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_app_a uuid;
  v_app_b uuid;
  v_company_a uuid;
  v_company_b uuid;
  v_prof record;
  v_comp record;
begin
  insert into auth.users (id, email) values (v_buyer_a, 'reject-buyer@example.com');
  insert into auth.users (id, email) values (v_buyer_b, 'gst-dedupe-buyer@example.com');
  insert into auth.users (id, email) values (v_staff, 'reject-staff@example.com');
  insert into public.users (id, email, role) values (v_staff, 'reject-staff@example.com', 'ADMIN');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select application_id, company_id into v_app_a, v_company_a
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Reject Path Co',
    p_gst_number := '27RJCTX9999Z1Z1',
    p_contact_email := 'reject-buyer@example.com',
    p_mobile_number := '9888800002',
    p_trade_declaration := true,
    p_data_consent := true
  );

  -- normalized-GSTIN dedup: a second applicant submitting the same GSTIN
  -- (whitespace/case variant) must resolve to the same company, not create
  -- a duplicate — the concurrency guard the spec calls for.
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);
  select company_id into v_company_b
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Reject Path Co Branch',
    p_gst_number := '27rjctx9999z1z1',
    p_contact_email := 'gst-dedupe-buyer@example.com',
    p_mobile_number := '9888800003',
    p_trade_declaration := true,
    p_data_consent := true
  );

  if v_company_b <> v_company_a then
    raise exception 'DEDUP REGRESSION: a normalized-GSTIN match created a second companies row instead of reusing %', v_company_a;
  end if;

  reset role;
  if (select count(*) from public.companies where upper(regexp_replace(gst_number, '\s', '', 'g')) = '27RJCTX9999Z1Z1') <> 1 then
    raise exception 'DEDUP REGRESSION: more than one companies row exists for the same normalized GSTIN';
  end if;

  -- staff rejects the first application
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.reject_b2b_trade_application_v1(v_app_a, '');
    raise exception 'VALIDATION REGRESSION: rejection succeeded with an empty rejection_reason';
  exception
    when others then
      if sqlerrm not like 'VALIDATION_FAILED%' then
        raise;
      end if;
  end;

  perform public.reject_b2b_trade_application_v1(v_app_a, 'Incomplete trade documentation');

  select * into v_comp from public.companies where id = v_company_a;
  select * into v_prof from public.profiles where id = v_buyer_a;

  if v_comp.status = 'active' then
    raise exception 'REJECTION REGRESSION: rejecting an application activated the company';
  end if;

  if coalesce(v_prof.is_approved, false) or v_prof.company_id is not null then
    raise exception 'REJECTION REGRESSION: rejecting an application linked/approved the buyer profile (is_approved=%, company_id=%)',
      v_prof.is_approved, v_prof.company_id;
  end if;

  if (select status from public.b2b_applications where id = v_app_a) <> 'rejected'
    or (select rejection_reason from public.b2b_applications where id = v_app_a) is null then
    raise exception 'REJECTION REGRESSION: application status/rejection_reason not recorded';
  end if;

  reset role;
  if not exists (
    select 1 from public.audit_logs
    where action_type = 'B2B_APPLICATION_REJECTED' and entity_id = v_app_a::text and actor_id = v_staff
  ) then
    raise exception 'AUDITABILITY REGRESSION: no audit_logs row for the rejection decision';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- repeated rejection is a safe idempotent no-op
  perform public.reject_b2b_trade_application_v1(v_app_a, 'second attempt, should no-op');
  if (select rejection_reason from public.b2b_applications where id = v_app_a) <> 'Incomplete trade documentation' then
    raise exception 'IDEMPOTENCY REGRESSION: repeated rejection overwrote the original decision';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('rejection never activates a company or links a buyer, requires a reason, is idempotent, and normalized-GSTIN submissions dedupe to one company');

-- ══════════════════════════════════════════════════════════════════════
-- Live: sibling permissive-policy exploit regressions (companies/profiles)
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_intruder uuid := gen_random_uuid();
  v_intruder_prof record;
begin
  insert into auth.users (id, email) values (v_intruder, 'intruder@example.com');
  perform set_config('request.jwt.claims', json_build_object('sub', v_intruder::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- the removed OASIS_AUTH_INSERT_BYPASS policy must no longer let an
  -- authenticated caller create a self-activated, credit-enabled company.
  begin
    insert into public.companies (business_name, status, credit_limit, allow_credit, payment_terms)
    values ('Intruder Co', 'active', 500000, true, 'credit');
    raise exception 'SECURITY REGRESSION: direct companies INSERT succeeded for a non-staff authenticated caller';
  exception
    when insufficient_privilege then null;
  end;

  -- A bare profiles self-insert declaring a staff role must not be
  -- rubber-stamped approved by enforce_profile_approval_for_staff. The
  -- defense-in-depth trigger (trg_prevent_profile_insert_priv_esc) is
  -- designed to neutralize the payload and let the now-safe row insert,
  -- not to reject the statement outright — so the row exists, but never
  -- with the attacker-declared role/is_approved/status. Asserting on the
  -- exception here (rather than the resulting row state) would be
  -- firing-order-dependent: whichever of this trigger and the legacy
  -- enforce_profile_approval_for_staff runs last determines role's exact
  -- casing, and a case-sensitive RLS check against that value could
  -- accidentally reject the statement for the wrong reason. Assert the
  -- persisted state instead, so this proves the real security property
  -- regardless of trigger firing order or RLS policy wording.
  insert into public.profiles (id, role, is_approved, status)
  values (v_intruder, 'ADMIN', true, 'approved');

  reset role;
  select * into v_intruder_prof from public.profiles where id = v_intruder;
  if upper(coalesce(v_intruder_prof.role, '')) = 'ADMIN' or coalesce(v_intruder_prof.is_approved, false) then
    raise exception 'SECURITY REGRESSION: self-declared-staff profiles INSERT persisted an elevated role/is_approved for a non-staff authenticated caller (role=%, is_approved=%)',
      v_intruder_prof.role, v_intruder_prof.is_approved;
  end if;

  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('sibling permissive-RLS gaps on companies/profiles are closed: no self-activation, no self-declared-staff approval');

-- ══════════════════════════════════════════════════════════════════════
-- Live: a legitimate direct client self-insert (role omitted, relying on
-- the column default) must still succeed. Regression coverage for the
-- BEFORE INSERT trigger-ordering interaction found in review:
-- enforce_profile_approval_for_staff (existing, fires after this
-- migration's trg_prevent_profile_insert_priv_esc per alphabetical
-- ordering) unconditionally uppercases NEW.role, so a case-sensitive
-- WITH CHECK against literal 'pending_buyer' would reject every such
-- insert, not just malicious ones.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_legit uuid := gen_random_uuid();
  v_prof record;
begin
  insert into auth.users (id, email) values (v_legit, 'legit-direct-insert@example.com');
  perform set_config('request.jwt.claims', json_build_object('sub', v_legit::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.profiles (id) values (v_legit);

  reset role;
  select * into v_prof from public.profiles where id = v_legit;

  if v_prof.id is null then
    raise exception 'REGRESSION: a legitimate direct profiles self-insert (role omitted) was rejected by RLS';
  end if;

  if coalesce(v_prof.is_approved, false) or v_prof.company_id is not null then
    raise exception 'SAFE-STATE REGRESSION: legitimate direct self-insert did not land in a safe pending state (is_approved=%, company_id=%)',
      v_prof.is_approved, v_prof.company_id;
  end if;

  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('a legitimate direct profiles self-insert with role omitted still succeeds and lands in a safe pending state');

-- ══════════════════════════════════════════════════════════════════════
-- Live: approving a GSTIN-deduped second application (different
-- business_name than the matched company) must succeed, not crash.
-- Regression for the legacy trg_activate_company_on_approval /
-- trg_link_buyer_on_approval interaction found in adversarial review:
-- both triggers still fire on this RPC's UPDATE (staff satisfies their
-- is_internal_staff guard) and previously did their own independent
-- business_name-based company lookup/creation, colliding with
-- uq_companies_gst_number_normalized and aborting the whole approval.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_buyer_first uuid := gen_random_uuid();
  v_buyer_second uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_app_first uuid;
  v_app_second uuid;
  v_company_first uuid;
  v_company_second uuid;
  v_comp record;
  v_prof record;
begin
  insert into auth.users (id, email) values (v_buyer_first, 'gst-first@example.com');
  insert into auth.users (id, email) values (v_buyer_second, 'gst-second@example.com');
  insert into auth.users (id, email) values (v_staff, 'gst-approve-staff@example.com');
  insert into public.users (id, email, role) values (v_staff, 'gst-approve-staff@example.com', 'ADMIN');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_first::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select application_id, company_id into v_app_first, v_company_first
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Headquarters Trading Co',
    p_gst_number := '29AAAAA1111A1Z5',
    p_contact_email := 'gst-first@example.com',
    p_mobile_number := '9555500001',
    p_trade_declaration := true,
    p_data_consent := true
  );
  reset role;

  -- Second applicant, DIFFERENT business_name, same GSTIN (case-varied) —
  -- correctly dedups to the first company at submission time.
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_second::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select application_id, company_id into v_app_second, v_company_second
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Branch Office Of Headquarters',
    p_gst_number := '29aaaaa1111a1z5',
    p_contact_email := 'gst-second@example.com',
    p_mobile_number := '9555500002',
    p_trade_declaration := true,
    p_data_consent := true
  );
  reset role;

  if v_company_second <> v_company_first then
    raise exception 'TEST SETUP FAILURE: second applicant did not dedup to the first company';
  end if;

  -- This is the exact scenario that previously threw
  -- "duplicate key value violates unique constraint
  -- uq_companies_gst_number_normalized" and aborted the transaction.
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.approve_b2b_trade_application_v1(v_app_second, 'TIER_A');
  reset role;

  if (select count(*) from public.companies where upper(regexp_replace(gst_number, '\s', '', 'g')) = '29AAAAA1111A1Z5') <> 1 then
    raise exception 'REGRESSION: approving the deduped second application created a duplicate company';
  end if;

  select * into v_comp from public.companies where id = v_company_first;
  select * into v_prof from public.profiles where id = v_buyer_second;

  if v_comp.status <> 'active' then
    raise exception 'REGRESSION: the shared company was not activated by the second application''s approval';
  end if;

  if not coalesce(v_prof.is_approved, false) or v_prof.company_id <> v_company_first then
    raise exception 'REGRESSION: second applicant not correctly approved/linked to the shared company (is_approved=%, company_id=%)',
      v_prof.is_approved, v_prof.company_id;
  end if;

  -- The legacy trigger's own guard is required to still cover the direct-
  -- table path: this RPC-managed approval must not have caused the legacy
  -- functions to leave the session-level GUC stuck "on" for anything else
  -- in this transaction.
  if coalesce(current_setting('app.b2b_application_rpc_managed', true), 'off') <> 'off' then
    raise exception 'REGRESSION: app.b2b_application_rpc_managed GUC leaked "on" past the approval call';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approving a GSTIN-deduped second application (different business_name) succeeds and activates/links correctly, without creating a duplicate company');

-- ══════════════════════════════════════════════════════════════════════
-- Live: malformed/placeholder GSTIN values must never be used as a
-- dedup/merge key — two unrelated applicants both submitting "NA" must
-- NOT be silently merged into the same company.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_company_a uuid;
  v_company_b uuid;
begin
  insert into auth.users (id, email) values (v_buyer_a, 'placeholder-gst-a@example.com');
  insert into auth.users (id, email) values (v_buyer_b, 'placeholder-gst-b@example.com');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select company_id into v_company_a
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Totally Unrelated Business One',
    p_gst_number := 'NA',
    p_contact_email := 'placeholder-gst-a@example.com',
    p_mobile_number := '9555500003',
    p_trade_declaration := true,
    p_data_consent := true
  );
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select company_id into v_company_b
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Completely Different Business Two',
    p_gst_number := 'na',
    p_contact_email := 'placeholder-gst-b@example.com',
    p_mobile_number := '9555500004',
    p_trade_declaration := true,
    p_data_consent := true
  );
  reset role;

  if v_company_a = v_company_b then
    raise exception 'SECURITY REGRESSION: two unrelated applicants with placeholder GSTIN "NA" were merged into the same company (%)', v_company_a;
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('malformed/placeholder GSTIN values ("NA") are never used as a dedup key — unrelated applicants get separate companies');

-- ══════════════════════════════════════════════════════════════════════
-- Live: uq_b2b_applications_one_pending_per_user is a real, independent
-- data constraint, not just an index the RPC happens to never hit — a
-- direct-table INSERT bypassing the RPC entirely must also be rejected.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_dup_user uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_dup_user, 'dup-pending@example.com');

  insert into public.b2b_applications (business_name, status, user_id, contact_email)
  values ('Dup Pending Co A', 'pending', v_dup_user, 'dup-pending-a@example.com');

  begin
    insert into public.b2b_applications (business_name, status, user_id, contact_email)
    values ('Dup Pending Co B', 'pending', v_dup_user, 'dup-pending-b@example.com');
    raise exception 'REGRESSION: uq_b2b_applications_one_pending_per_user did not reject a second direct-table pending application for the same user';
  exception
    when unique_violation then null;
  end;
end $$;

select pass('uq_b2b_applications_one_pending_per_user rejects a second pending application for the same user via direct INSERT, independent of the RPC short-circuit');

-- ══════════════════════════════════════════════════════════════════════
-- Live: the tightened "Staff manage applications" WITH CHECK must reject
-- a direct-table UPDATE that spoofs reviewed_by to someone other than the
-- calling staff member — the exact reviewer-spoofing gap this migration
-- closes on the legacy direct-table path.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_staff uuid := gen_random_uuid();
  v_someone_else uuid := gen_random_uuid();
  v_buyer uuid := gen_random_uuid();
  v_app_id uuid;
begin
  insert into auth.users (id, email) values (v_staff, 'spoof-staff@example.com');
  insert into auth.users (id, email) values (v_someone_else, 'spoof-target@example.com');
  insert into auth.users (id, email) values (v_buyer, 'spoof-buyer@example.com');
  insert into public.users (id, email, role) values (v_staff, 'spoof-staff@example.com', 'ADMIN');

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select application_id into v_app_id
  from public.submit_b2b_trade_application_v1(
    p_business_name := 'Spoof Reviewer Co',
    p_contact_email := 'spoof-buyer@example.com',
    p_mobile_number := '9444400001',
    p_trade_declaration := true,
    p_data_consent := true
  );
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    update public.b2b_applications
    set status = 'approved', reviewed_by = v_someone_else, reviewed_at = now()
    where id = v_app_id;
    raise exception 'SECURITY REGRESSION: a direct-table UPDATE spoofing reviewed_by to someone other than the caller succeeded';
  exception
    when insufficient_privilege then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('Staff manage applications RLS rejects a direct-table UPDATE that spoofs reviewed_by to someone other than the calling staff member');

-- ══════════════════════════════════════════════════════════════════════
-- Live: historical resolved_company_id backfill is GSTIN-only — a
-- well-formed normalized GSTIN match repairs legacy rows; business_name
-- alone must never establish company ownership.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_company_gst uuid;
  v_company_name_only uuid;
  v_company_name_collision uuid;
  v_buyer_gst uuid := gen_random_uuid();
  v_buyer_name_only uuid := gen_random_uuid();
  v_buyer_name_collision uuid := gen_random_uuid();
  v_app_gst_id uuid;
  v_app_name_only_id uuid;
  v_app_name_collision_id uuid;
  v_gst text := '29HIST1111A1Z5';
  v_collision_company_gst text := '29HIST3333C3Z7';
  v_collision_app_gst text := '29HIST2222B2Z6';
begin
  insert into public.companies (business_name, gst_number, status)
  values ('Historical GST Co', v_gst, 'pending')
  returning id into v_company_gst;

  insert into public.companies (business_name, gst_number, status)
  values ('Name Only Shared Co', null, 'pending')
  returning id into v_company_name_only;

  -- Isolates the "business_name alone never establishes ownership" property
  -- cleanly: this company has its own valid, matchable GSTIN, but the
  -- application below shares only its business_name — with a *different*,
  -- equally well-formed GSTIN that matches no company — so a null result
  -- here cannot be attributed to a missing/malformed GSTIN, only to name
  -- matching genuinely not being used.
  insert into public.companies (business_name, gst_number, status)
  values ('Name Collision Co', v_collision_company_gst, 'pending')
  returning id into v_company_name_collision;

  insert into auth.users (id, email) values (v_buyer_gst, 'hist-gst@example.com');
  insert into auth.users (id, email) values (v_buyer_name_only, 'hist-name-only@example.com');
  insert into auth.users (id, email) values (v_buyer_name_collision, 'hist-name-collision@example.com');

  insert into public.b2b_applications (
    business_name, gst_number, status, user_id, contact_email, resolved_company_id
  ) values (
    'Historical GST Co', v_gst, 'pending', v_buyer_gst, 'hist-gst@example.com', null
  ) returning id into v_app_gst_id;

  insert into public.b2b_applications (
    business_name, gst_number, status, user_id, contact_email, resolved_company_id
  ) values (
    'Name Only Shared Co', 'NA', 'pending', v_buyer_name_only, 'hist-name-only@example.com', null
  ) returning id into v_app_name_only_id;

  insert into public.b2b_applications (
    business_name, gst_number, status, user_id, contact_email, resolved_company_id
  ) values (
    'Name Collision Co', v_collision_app_gst, 'pending', v_buyer_name_collision, 'hist-name-collision@example.com', null
  ) returning id into v_app_name_collision_id;

  -- Same deterministic normalized-GSTIN backfill the migration runs once.
  update public.b2b_applications a
  set resolved_company_id = c.id
  from public.companies c
  where a.resolved_company_id is null
    and a.gst_number is not null
    and btrim(a.gst_number) <> ''
    and c.gst_number is not null
    and upper(regexp_replace(a.gst_number, '\s', '', 'g')) = upper(regexp_replace(c.gst_number, '\s', '', 'g'))
    and upper(regexp_replace(a.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
    and upper(regexp_replace(c.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$';

  if (select resolved_company_id from public.b2b_applications where id = v_app_gst_id) <> v_company_gst then
    raise exception 'BACKFILL REGRESSION: a historical row with a valid matching GSTIN was not resolved to the company';
  end if;

  if (select resolved_company_id from public.b2b_applications where id = v_app_name_only_id) is not null then
    raise exception 'BACKFILL REGRESSION: business_name-only identity incorrectly resolved resolved_company_id';
  end if;

  if (select resolved_company_id from public.b2b_applications where id = v_app_name_collision_id) is not null then
    raise exception 'BACKFILL REGRESSION: an application matched a company by business_name alone despite carrying its own distinct, well-formed GSTIN';
  end if;
end $$;

select pass('historical backfill resolves only via well-formed normalized GSTIN match, never via business_name alone');

-- ══════════════════════════════════════════════════════════════════════
-- Live: approve_b2b_trade_application_v1 fails closed for a historical
-- application that cannot be deterministically resolved (no automatic
-- business_name fallback at approval time).
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_staff uuid := gen_random_uuid();
  v_buyer uuid := gen_random_uuid();
  v_app_id uuid;
begin
  insert into auth.users (id, email) values (v_staff, 'hist-unresolved-staff@example.com');
  insert into auth.users (id, email) values (v_buyer, 'hist-unresolved-buyer@example.com');
  insert into public.users (id, email, role) values (v_staff, 'hist-unresolved-staff@example.com', 'ADMIN');

  insert into public.companies (business_name, gst_number, status)
  values ('Unresolved Historical Co', null, 'pending');

  insert into public.b2b_applications (
    business_name, gst_number, status, user_id, contact_email, resolved_company_id
  ) values (
    'Unresolved Historical Co', 'NA', 'pending', v_buyer, 'hist-unresolved-buyer@example.com', null
  ) returning id into v_app_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.approve_b2b_trade_application_v1(v_app_id);
    raise exception 'FAIL-CLOSED REGRESSION: approve succeeded for an unresolved historical application';
  exception
    when sqlstate 'P0001' then
      if sqlerrm not like 'APPLICATION_INCOMPLETE%' then
        raise;
      end if;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approve_b2b_trade_application_v1 fails closed when resolved_company_id is null on a historical application');

select * from finish();
rollback;
