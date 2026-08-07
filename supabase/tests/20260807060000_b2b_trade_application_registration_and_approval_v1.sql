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

select plan(24);

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
    and not has_function_privilege('authenticated', 'public.approve_b2b_trade_application_v1(uuid,text,text)', 'EXECUTE') is not true
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
  if v_prof.role = 'ADMIN' or coalesce(v_prof.is_approved, false) or v_prof.company_id is not null or v_prof.price_tier is not null then
    raise exception 'SECURITY REGRESSION: applicant self-update escalated privileged profile fields (role=%, is_approved=%, company_id=%, price_tier=%)',
      v_prof.role, v_prof.is_approved, v_prof.company_id, v_prof.price_tier;
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

  -- approved buyer reaches the exact state the customer _v1 contracts need
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  perform public.buyer_product_prices_v1();
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

  -- a bare profiles self-insert declaring a staff role must not be
  -- rubber-stamped approved by enforce_profile_approval_for_staff.
  begin
    insert into public.profiles (id, role, is_approved, status)
    values (v_intruder, 'ADMIN', true, 'approved');
    raise exception 'SECURITY REGRESSION: self-declared-staff profiles INSERT succeeded for a non-staff authenticated caller';
  exception
    when insufficient_privilege then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('sibling permissive-RLS gaps on companies/profiles are closed: no self-activation, no self-declared-staff approval');

select * from finish();
rollback;
