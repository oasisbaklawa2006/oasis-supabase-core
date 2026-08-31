-- Contract test for 20260807053000_harden_privileged_approval_and_credit_triggers.sql
--
-- Regression coverage for two privilege-escalation paths:
--   1. b2b_applications self-approval via permissive anon/public INSERT
--      feeding trg_activate_company_on_approval / trg_link_buyer_on_approval.
--   2. order_payments credit-unlock via fabricated/self-verified 'rescue'
--      payments feeding handle_credit_payment.
--
-- Follows this repository's established static/introspective pgTAP style
-- (pg_policies / pg_get_functiondef / trigger_is), matching
-- 20260730_critical_master_table_rls.sql and
-- 20260727_privileged_rpc_execution.sql, plus live role-simulated exploit
-- attempts for the properties static introspection cannot prove.
begin;

select plan(27);

-- ── b2b_applications: exploit-precondition removal ──────────────────────

select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename='b2b_applications' and policyname='ANON_CAN_SUBMIT_APPLICATION'),
  'legacy unrestricted anon-submit policy is removed'
);

select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename='b2b_applications' and policyname='Anyone can apply'),
  'legacy unrestricted public-submit policy is removed'
);

select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename='b2b_applications' and policyname='Applicants insert own application'),
  'legacy loosely-scoped applicant-insert policy is removed'
);

select is(
  (
    select count(*)::integer
    from pg_policies
    where schemaname = 'public'
      and tablename = 'b2b_applications'
      and cmd = 'INSERT'
      and coalesce(with_check, '') = 'true'
  ),
  0,
  'no b2b_applications INSERT policy retains an unrestricted WITH CHECK (true) — the original exploit precondition is gone'
);

select ok(
  exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='b2b_applications'
      and policyname='Applicants submit safe pending application'
      and cmd='INSERT'
      and with_check like '%status = ''pending''%'
      and with_check like '%reviewed_by IS NULL%'
      and with_check like '%reviewed_at IS NULL%'
      and with_check like '%assigned_price_tier IS NULL%'
  ),
  'new applicant-insert policy forces status=pending and blocks every reviewer-owned field at insert time'
);

select ok(
  exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='b2b_applications'
      and policyname='Applicants submit safe pending application'
      and 'anon' = any(roles) and 'authenticated' = any(roles)
  ),
  'the safe applicant-insert policy still covers both anon and authenticated (legitimate pre-auth submission preserved)'
);

-- UPDATE was already staff-only before this migration and is untouched here
-- — confirms no equivalent escalation path was left open on UPDATE.
select ok(
  exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='b2b_applications'
      and policyname='Staff manage applications' and cmd='UPDATE'
      and qual like '%is_internal_staff%' and with_check like '%is_internal_staff%'
  ),
  'b2b_applications UPDATE remains staff-only via is_internal_staff (unchanged, confirmed no parallel UPDATE escalation exists)'
);

select is(
  (
    select count(*)::integer
    from pg_policies
    where schemaname = 'public'
      and tablename = 'b2b_applications'
      and cmd = 'UPDATE'
  ),
  1,
  'exactly one UPDATE policy exists on b2b_applications (staff-only) — no new UPDATE surface was introduced'
);

-- ── b2b_applications: trigger-level defense in depth ─────────────────────

select ok(
  pg_get_functiondef('public.activate_company_on_application_approval()'::regprocedure) like '%is_internal_staff%',
  'activate_company_on_application_approval carries an explicit staff/service_role authority guard'
);

select ok(
  pg_get_functiondef('public.link_buyer_on_application_approval()'::regprocedure) like '%is_internal_staff%',
  'link_buyer_on_application_approval carries an explicit staff/service_role authority guard'
);

select trigger_is(
  'public', 'b2b_applications', 'trg_activate_company_on_approval',
  'public', 'activate_company_on_application_approval',
  'company-activation trigger still wired to the hardened function'
);

select trigger_is(
  'public', 'b2b_applications', 'trg_link_buyer_on_approval',
  'public', 'link_buyer_on_application_approval',
  'buyer-linking trigger still wired to the hardened function'
);

select ok(
  not has_function_privilege('anon', 'public.activate_company_on_application_approval()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.activate_company_on_application_approval()', 'EXECUTE'),
  'activate_company_on_application_approval is no longer directly executable by anon/authenticated (trigger-only, least privilege)'
);

select ok(
  not has_function_privilege('anon', 'public.link_buyer_on_application_approval()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.link_buyer_on_application_approval()', 'EXECUTE'),
  'link_buyer_on_application_approval is no longer directly executable by anon/authenticated (trigger-only, least privilege)'
);

-- ── exploit regression: the literal original attack, attempted live ─────
-- An anon INSERT with status already 'approved' must be rejected by RLS
-- before either trigger ever runs. Also isolate status='approved' alone
-- (no user_id) so this doesn't just prove the user_id predicate, and prove
-- a genuine pending submission still works.
set local role anon;

select throws_ok(
  $$ insert into public.b2b_applications (business_name, status, user_id, contact_email)
     values ('Exploit Co', 'approved', gen_random_uuid(), 'exploit@example.com') $$,
  '42501',
  null,
  'anon cannot insert a pre-approved application (original self-approval exploit is blocked)'
);

select throws_ok(
  $$ insert into public.b2b_applications (business_name, status, contact_email)
     values ('Exploit Co 2', 'approved', 'exploit2@example.com') $$,
  '42501',
  null,
  'status=approved alone is rejected for anon, independent of user_id'
);

select lives_ok(
  $$ insert into public.b2b_applications (business_name, status, contact_email)
     values ('Legit Applicant Co', 'pending', 'legit@example.com') $$,
  'anon can still submit a genuine pending application'
);

reset role;

-- ── order_payments: exploit-precondition removal ─────────────────────────

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='order_payments'
      and policyname='Buyers insert own company payments'
  )
  and exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='order_payments'
      and policyname='Finance staff manage order payments'
      and cmd='ALL'
      and qual like '%is_internal_staff%'
      and with_check like '%is_internal_staff%'
  ),
  'direct buyer order_payments INSERT authority is retired; canonical writes are Finance-governed'
);

-- The weaker duplicate policy is removed outright, not patched: it omitted
-- the company_id/created_by ownership checks entirely, so its mere presence
-- (RLS INSERT policies are OR'ed) would silently reopen the exploit.
select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename='order_payments' and policyname='buyer_insert_own_order_payments'),
  'the weaker duplicate buyer_insert_own_order_payments policy is removed, not just patched'
);

select ok(
  pg_get_functiondef('public.handle_credit_payment()'::regprocedure) like '%status is distinct from ''verified''%',
  'handle_credit_payment only proceeds past the early-return guard for finance-verified payments'
);

select ok(
  pg_get_functiondef('public.handle_credit_payment()'::regprocedure) like '%and status = ''verified''%',
  'the cumulative rescue-sum query itself also excludes unverified payments (defense in depth alongside the early-return guard)'
);

select ok(
  pg_get_functiondef('public.handle_credit_payment()'::regprocedure) like '%credit_rescue_events%'
    and pg_get_functiondef('public.handle_credit_payment()'::regprocedure) like '%audit_logs%',
  'automated credit unfreeze still writes an audit_logs entry and a credit_rescue_events entry (preserved from the original function, not dropped by the security rewrite)'
);

select trigger_is(
  'public', 'order_payments', 'trg_credit_payment',
  'public', 'handle_credit_payment',
  'insert-time credit-rescue trigger still wired to the hardened function'
);

select trigger_is(
  'public', 'order_payments', 'trg_credit_payment_verified',
  'public', 'handle_credit_payment',
  'new update-time credit-rescue trigger fires when finance actually verifies a payment (fixes a latent gap: verification previously never re-evaluated the unlock condition)'
);

select ok(
  not has_function_privilege('anon', 'public.handle_credit_payment()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.handle_credit_payment()', 'EXECUTE'),
  'handle_credit_payment is no longer directly executable by anon/authenticated (trigger-only, least privilege)'
);

-- ── exploit regression: fabricated rescue payment, attempted live ───────
-- Direct buyer writes are no longer an authority path at all. Both a forged
-- verified payment and a superficially benign uploaded payment must be rejected
-- by RLS; payment evidence enters through the governed payment-proof authority.
do $$
declare
  v_company_id uuid;
  v_order_id uuid;
  v_user_id uuid := gen_random_uuid();
  v_staff_id uuid := gen_random_uuid();
begin
  insert into public.companies (business_name, status, is_frozen, total_outstanding)
  values ('Rescue Exploit Co', 'active', false, 100000)
  returning id into v_company_id;

  insert into public.orders (company_id, status, sales_order_value, tracking_token, order_origin)
  values (v_company_id, 'submitted', 50000, md5(random()::text), 'SALES')
  returning id into v_order_id;

  insert into public.users (id, email, role, company_id)
  values (v_staff_id, 'staff@example.com', 'ADMIN', null);
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff_id::text, 'role', 'authenticated')::text, true);
  perform set_config('app.system_credit_op', 'on', true);
  update public.companies set is_frozen = true where id = v_company_id;
  perform set_config('app.system_credit_op', 'off', true);

  insert into auth.users (id, email)
  values (v_user_id, 'buyer@example.com');

  insert into public.users (id, email, role, company_id)
  values (v_user_id, 'buyer@example.com', 'b2b_buyer', v_company_id);

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.order_payments (order_id, company_id, payment_type, amount, status, created_by)
    values (v_order_id, v_company_id, 'rescue', 999999, 'verified', v_user_id);
    raise exception 'SECURITY REGRESSION: buyer inserted a self-verified rescue payment';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    insert into public.order_payments (order_id, company_id, payment_type, amount, status, created_by)
    values (v_order_id, v_company_id, 'rescue', 999999, 'uploaded', v_user_id);
    raise exception 'SECURITY REGRESSION: buyer directly inserted an uploaded order payment';
  exception
    when insufficient_privilege then
      null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('buyer cannot directly insert order_payments in either verified or uploaded state; governed payment-proof authority is required');

-- ── positive regression: legitimate staff verification still unlocks ────

do $$
declare
  v_company_id uuid;
  v_order_id uuid;
  v_payment_id uuid;
  v_frozen boolean;
  v_staff_id uuid := gen_random_uuid();
begin
  insert into public.companies (business_name, status, is_frozen, total_outstanding)
  values ('Legit Rescue Co', 'active', false, 1000)
  returning id into v_company_id;

  insert into public.orders (company_id, status, sales_order_value, tracking_token, order_origin)
  values (v_company_id, 'submitted', 1000, md5(random()::text), 'SALES')
  returning id into v_order_id;

  -- A genuine Finance verification is performed by an authenticated staff
  -- session. Keep that identity active through the trigger-driven unfreeze.
  insert into auth.users (id, email)
  values (v_staff_id, 'staff2@example.com');

  insert into public.users (id, email, role, company_id)
  values (v_staff_id, 'staff2@example.com', 'ADMIN', null);
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff_id::text, 'role', 'authenticated')::text, true);

  perform set_config('app.system_credit_op', 'on', true);
  update public.companies set is_frozen = true where id = v_company_id;
  perform set_config('app.system_credit_op', 'off', true);

  insert into public.order_payments (order_id, company_id, payment_type, amount, status)
  values (v_order_id, v_company_id, 'rescue', 700, 'uploaded')
  returning id into v_payment_id;

  update public.order_payments set status = 'verified' where id = v_payment_id;

  perform set_config('request.jwt.claims', null, true);

  select is_frozen into v_frozen from public.companies where id = v_company_id;
  if v_frozen then
    raise exception 'EXPECTED BEHAVIOR MISSING: verified rescue payment reaching 70%% threshold should unfreeze the company';
  end if;
end $$;

select pass('a genuinely finance-verified rescue payment reaching the 70% threshold still unfreezes the company (feature preserved, not just blocked)');

select * from finish();
rollback;
