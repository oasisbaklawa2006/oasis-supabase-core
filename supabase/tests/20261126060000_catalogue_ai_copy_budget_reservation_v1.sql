-- Contract and behaviour tests for 20261126060000_catalogue_ai_copy_budget_reservation_v1.sql
-- APPVERSE-CORE-AI-BUDGET-01. Transactional pgTAP: no provider call, no external effect, rolled back.
BEGIN;
SELECT * FROM no_plan();

-- ---------------------------------------------------------------- structure and privileges
SELECT has_table('public', 'catalogue_ai_copy_budget_policy_v1', 'policy table exists');
SELECT has_table('public', 'catalogue_ai_copy_reservations_v1', 'reservation ledger exists');
SELECT has_table('public', 'catalogue_ai_copy_usage_v1', 'usage buckets exist');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN (
  'public.catalogue_ai_copy_budget_policy_v1'::regclass,
  'public.catalogue_ai_copy_reservations_v1'::regclass,
  'public.catalogue_ai_copy_usage_v1'::regclass)), 'RLS enabled on all three tables');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM unnest(ARRAY['anon','authenticated','service_role']) r,
         unnest(ARRAY['public.catalogue_ai_copy_budget_policy_v1','public.catalogue_ai_copy_reservations_v1','public.catalogue_ai_copy_usage_v1']) t,
         unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p
   WHERE has_table_privilege(r, t, p)), 'no API role has any direct table privilege');

SELECT is((SELECT array_agg(proname::text ORDER BY proname) FROM pg_proc
            WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'catalogue_ai_copy_budget%'),
  ARRAY['catalogue_ai_copy_budget_emergency_disable_v1','catalogue_ai_copy_budget_gate_v1',
        'catalogue_ai_copy_budget_mark_ambiguous_v1','catalogue_ai_copy_budget_reserve_v1',
        'catalogue_ai_copy_budget_settle_v1'],
  'exactly five budget RPCs exist; none can clear the emergency latch or raise a limit');

SELECT ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'catalogue_ai_copy_budget%'
    AND NOT (p.prosecdef AND p.proconfig @> ARRAY['search_path=""'])), 'every budget RPC is SECURITY DEFINER with an empty search_path');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'catalogue_ai_copy_budget%'
    AND (NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      OR has_function_privilege('anon', p.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      OR EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.privilege_type = 'EXECUTE' AND a.grantee = 0))),
  'service_role alone can execute every budget RPC (not anon, authenticated or PUBLIC)');

-- ---------------------------------------------------------------- seeded policy and CHECK ceilings
SELECT ok((SELECT NOT enabled AND emergency_disabled_at IS NULL FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton),
  'disabled by default, latch clear');
SELECT is((SELECT approved_model FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'gpt-5.4-mini-2026-03-17', 'pinned model snapshot');
SELECT is((SELECT ARRAY[input_micro_usd_per_million_tokens, output_micro_usd_per_million_tokens, max_input_tokens, max_output_tokens,
                         max_reservation_micro_usd, per_user_minute_limit, per_user_day_requests, per_user_day_micro_usd,
                         company_day_micro_usd, company_month_micro_usd]
             FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton),
  ARRAY[750000,4500000,8000,1400,15000,5,100,1000000,5000000,50000000], 'approved policy values');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET company_day_micro_usd = 5000001$$, '23514', NULL, 'company day cannot exceed the approved ceiling');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET company_month_micro_usd = 50000001$$, '23514', NULL, 'company month cannot exceed the approved ceiling');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET per_user_day_micro_usd = 1000001$$, '23514', NULL, 'user day money cannot exceed the approved ceiling');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET per_user_day_requests = 101$$, '23514', NULL, 'user day requests cannot exceed the approved ceiling');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET per_user_minute_limit = 6$$, '23514', NULL, 'user minute limit cannot exceed the approved ceiling');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET max_input_tokens = 8001$$, '23514', NULL, 'input ceiling cannot exceed 8,000');
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET max_reservation_micro_usd = 12299$$, '23514', NULL, 'reservation must always cover the worst-case cost');

-- ---------------------------------------------------------------- unauthorized RPC access
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17')$$, '42501', NULL, 'anon cannot call gate');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_reserve_v1('94780000-0000-0000-0000-0000000000f1', '94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17', 100)$$, '42501', NULL, 'anon cannot call reserve');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_settle_v1('94780000-0000-0000-0000-0000000000f1', 1, 1, 'x', 'm', 'default')$$, '42501', NULL, 'anon cannot call settle');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17')$$, '42501', NULL, 'authenticated cannot call gate');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_reserve_v1('94780000-0000-0000-0000-0000000000f1', '94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17', 100)$$, '42501', NULL, 'authenticated cannot call reserve');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_settle_v1('94780000-0000-0000-0000-0000000000f1', 1, 1, 'x', 'm', 'default')$$, '42501', NULL, 'authenticated cannot call settle');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_mark_ambiguous_v1('94780000-0000-0000-0000-0000000000f1')$$, '42501', NULL, 'authenticated cannot call mark_ambiguous');
SELECT throws_ok($$SELECT public.catalogue_ai_copy_budget_emergency_disable_v1('x')$$, '42501', NULL, 'authenticated cannot call emergency_disable');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT throws_ok($$UPDATE public.catalogue_ai_copy_budget_policy_v1 SET company_day_micro_usd = 1$$, '42501', NULL, 'service_role has no direct policy write');
SELECT throws_ok($$SELECT 1 FROM public.catalogue_ai_copy_usage_v1$$, '42501', NULL, 'service_role has no direct ledger read');
RESET ROLE;

-- ---------------------------------------------------------------- synthetic staff fixture (rolled back)
SET LOCAL session_replication_role = replica;
INSERT INTO auth.users(id, email)
SELECT ('94780000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'qa-budget-' || n || '@example.invalid'
  FROM generate_series(1, 14) n;
INSERT INTO public.users(id, email, role, is_active, invite_status)
SELECT ('94780000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'qa-budget-' || n || '@example.invalid', 'SUPER_ADMIN', true, 'active'
  FROM generate_series(1, 14) n;
SET LOCAL session_replication_role = origin;

-- ---------------------------------------------------------------- disabled by default
SET LOCAL ROLE service_role;
SELECT is(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17'), NULL::uuid, 'disabled policy: gate denies (fail closed)');
RESET ROLE;
UPDATE public.catalogue_ai_copy_budget_policy_v1 SET enabled = true WHERE singleton;

SET LOCAL ROLE service_role;
SELECT is(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-0000000000a0', 'gpt-5.4-mini-2026-03-17'), NULL::uuid, 'non-staff actor denied');
SELECT is(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini'), NULL::uuid, 'unapproved model denied (no substitution)');
SELECT is(public.catalogue_ai_copy_budget_gate_v1(NULL, 'gpt-5.4-mini-2026-03-17'), NULL::uuid, 'null actor denied');

-- per-user minute limit: exactly five slots
SELECT is((SELECT count(*) FROM (SELECT public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000002', 'gpt-5.4-mini-2026-03-17') g
            FROM generate_series(1, 7)) s WHERE g IS NOT NULL), 5::bigint, 'exactly five gate slots per user per UTC minute');
RESET ROLE;
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';

-- ---------------------------------------------------------------- reserve (atomic) and settle
SET LOCAL ROLE service_role;
SELECT set_config('t.g1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000003', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT isnt(current_setting('t.g1'), '', 'gate returns a reservation id');
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g1')::uuid, '94780000-0000-0000-0000-000000000003', 'gpt-5.4-mini-2026-03-17', 1200), true, 'reservation granted');
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g1')::uuid, '94780000-0000-0000-0000-000000000003', 'gpt-5.4-mini-2026-03-17', 1200), false, 'a reservation cannot be reserved twice');
RESET ROLE;
SELECT is((SELECT ARRAY[status, reserved_micro_usd::text, counted_input_tokens::text] FROM public.catalogue_ai_copy_reservations_v1 WHERE reservation_id = current_setting('t.g1')::uuid),
  ARRAY['reserved', '15000', '1200'], 'ledger row holds the maximum reservation');
SELECT is((SELECT ARRAY[requests::text, micro_usd::text] FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_day' AND actor_id = '94780000-0000-0000-0000-000000000003'),
  ARRAY['1', '15000'], 'user day bucket advanced atomically');
SELECT is((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000'), 15000::bigint, 'company day bucket advanced in the same transaction');
SELECT is((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000'), 15000::bigint, 'company month bucket advanced in the same transaction');

SET LOCAL ROLE service_role;
SELECT is((public.catalogue_ai_copy_budget_settle_v1(current_setting('t.g1')::uuid, 1000, 500, 'req-1', 'gpt-5.4-mini-2026-03-17', 'default')->>'charged_micro_usd')::int, 3000, 'settled at verified usage (750 + 2250 micro-USD)');
SELECT is(public.catalogue_ai_copy_budget_settle_v1(current_setting('t.g1')::uuid, 8000, 1400, 'req-dup', 'gpt-5.4-mini-2026-03-17', 'default')->>'replayed', 'true', 'duplicate settlement is a replay');
RESET ROLE;
SELECT is((SELECT charged_micro_usd FROM public.catalogue_ai_copy_reservations_v1 WHERE reservation_id = current_setting('t.g1')::uuid), 3000, 'duplicate settlement did not change the charge');
SELECT is((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000'), 3000::bigint, 'buckets credited once after settlement');
SELECT is((SELECT requests FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_day' AND actor_id = '94780000-0000-0000-0000-000000000003'), 1, 'request count is not refunded by settlement');
SELECT ok((SELECT emergency_disabled_at IS NULL FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'clean settlement does not trip the latch');

-- maximum verified usage: charge equals verified, within the reservation
SET LOCAL ROLE service_role;
SELECT set_config('t.g2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000004', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g2')::uuid, '94780000-0000-0000-0000-000000000004', 'gpt-5.4-mini-2026-03-17', 8000), true, 'reservation at the 8,000-token ceiling');
SELECT is((public.catalogue_ai_copy_budget_settle_v1(current_setting('t.g2')::uuid, 8000, 1400, 'req-max', 'gpt-5.4-mini-2026-03-17', 'default')->>'charged_micro_usd')::int, 12300, 'worst-case verified usage is charged exactly');
RESET ROLE;

-- reserve denials
SET LOCAL ROLE service_role;
SELECT set_config('t.g3', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g3')::uuid, '94780000-0000-0000-0000-000000000006', 'gpt-5.4-mini-2026-03-17', 100), false, 'a different actor cannot use the gate');
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g3')::uuid, '94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17', 8001), false, 'counted input above 8,000 is refused');
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g3')::uuid, '94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17', 100), false, 'a denied gate cannot be revived');
SELECT set_config('t.g4', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g4')::uuid, '94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-other', 100), false, 'model mismatch at reserve is refused');
SELECT set_config('t.g5', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
RESET ROLE;
UPDATE public.catalogue_ai_copy_reservations_v1 SET created_at = now() - interval '6 minutes' WHERE reservation_id = current_setting('t.g5')::uuid;
SET LOCAL ROLE service_role;
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.g5')::uuid, '94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17', 100), false, 'an expired gate cannot be reserved');
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(gen_random_uuid(), '94780000-0000-0000-0000-000000000005', 'gpt-5.4-mini-2026-03-17', 100), false, 'an unknown reservation id is refused');
RESET ROLE;

-- ---------------------------------------------------------------- budget exhaustion at the exact boundary
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';
-- per-user day money: 985,000 + 15,000 = 1,000,000 is allowed; the next is not
INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests, micro_usd)
VALUES ('user_day', ((now() AT TIME ZONE 'UTC')::date)::timestamp AT TIME ZONE 'UTC', '94780000-0000-0000-0000-000000000007', 1, 985000);
SET LOCAL ROLE service_role;
SELECT set_config('t.u1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000007', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.u1')::uuid, '94780000-0000-0000-0000-000000000007', 'gpt-5.4-mini-2026-03-17', 100), true, 'user $1 cap: the exact boundary is allowed');
SELECT set_config('t.u2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000007', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.u2')::uuid, '94780000-0000-0000-0000-000000000007', 'gpt-5.4-mini-2026-03-17', 100), false, 'user $1 cap: one micro-USD over is denied');
RESET ROLE;
-- per-user day requests: 99 allowed -> 100th ok, 101st denied
INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests, micro_usd)
VALUES ('user_day', ((now() AT TIME ZONE 'UTC')::date)::timestamp AT TIME ZONE 'UTC', '94780000-0000-0000-0000-000000000008', 99, 0);
SET LOCAL ROLE service_role;
SELECT set_config('t.r1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000008', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.r1')::uuid, '94780000-0000-0000-0000-000000000008', 'gpt-5.4-mini-2026-03-17', 100), true, 'user 100-request cap: the 100th request is allowed');
SELECT set_config('t.r2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000008', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.r2')::uuid, '94780000-0000-0000-0000-000000000008', 'gpt-5.4-mini-2026-03-17', 100), false, 'user 100-request cap: the 101st request is denied');
RESET ROLE;
-- company day: 4,985,000 + 15,000 = 5,000,000 allowed; next denied (other users, so only the company cap binds)
UPDATE public.catalogue_ai_copy_usage_v1 SET micro_usd = 4985000 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000';
SET LOCAL ROLE service_role;
SELECT set_config('t.c1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000009', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.c1')::uuid, '94780000-0000-0000-0000-000000000009', 'gpt-5.4-mini-2026-03-17', 100), true, 'company $5/day cap: exact boundary allowed');
SELECT set_config('t.c2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000010', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.c2')::uuid, '94780000-0000-0000-0000-000000000010', 'gpt-5.4-mini-2026-03-17', 100), false, 'company $5/day cap: over the boundary denied');
RESET ROLE;
UPDATE public.catalogue_ai_copy_usage_v1 SET micro_usd = 0 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000';
-- company month: 49,985,000 + 15,000 = 50,000,000 allowed; next denied
UPDATE public.catalogue_ai_copy_usage_v1 SET micro_usd = 49985000 WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000';
SET LOCAL ROLE service_role;
SELECT set_config('t.m1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000011', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.m1')::uuid, '94780000-0000-0000-0000-000000000011', 'gpt-5.4-mini-2026-03-17', 100), true, 'company $50/month cap: exact boundary allowed');
SELECT set_config('t.m2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.m2')::uuid, '94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17', 100), false, 'company $50/month cap: over the boundary denied');
RESET ROLE;
UPDATE public.catalogue_ai_copy_usage_v1 SET micro_usd = 0 WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000';
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';

-- ---------------------------------------------------------------- ambiguous provider failures
SET LOCAL ROLE service_role;
SELECT set_config('t.a1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000013', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.a1')::uuid, '94780000-0000-0000-0000-000000000013', 'gpt-5.4-mini-2026-03-17', 100), true, 'reservation for an ambiguous outcome');
SELECT is(public.catalogue_ai_copy_budget_mark_ambiguous_v1(current_setting('t.a1')::uuid)->>'status', 'ambiguous', 'timeout or 5xx: marked ambiguous');
SELECT is((public.catalogue_ai_copy_budget_settle_v1(current_setting('t.a1')::uuid, 10, 10, 'late', 'gpt-5.4-mini-2026-03-17', 'default')->>'replayed'), 'true', 'a late settle cannot release an ambiguous reservation');
SELECT is((public.catalogue_ai_copy_budget_mark_ambiguous_v1(current_setting('t.a1')::uuid)->>'charged_micro_usd')::int, 15000, 'ambiguous keeps the FULL reservation');
SELECT is(public.catalogue_ai_copy_budget_mark_ambiguous_v1(current_setting('t.g1')::uuid)->>'status', 'settled', 'a settled reservation is never downgraded');
SELECT set_config('t.a2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000013', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.a2')::uuid, '94780000-0000-0000-0000-000000000013', 'gpt-5.4-mini-2026-03-17', 100), true, 'second reservation (unverifiable usage)');
SELECT is(public.catalogue_ai_copy_budget_settle_v1(current_setting('t.a2')::uuid, NULL, NULL, 'x', 'gpt-5.4-mini-2026-03-17', 'default')->>'status', 'ambiguous', 'missing usage keeps the full reservation');
RESET ROLE;
SELECT is((SELECT charged_micro_usd FROM public.catalogue_ai_copy_reservations_v1 WHERE reservation_id = current_setting('t.a2')::uuid), 15000, 'unverifiable usage is charged at the full reservation');

-- ---------------------------------------------------------------- UTC rollover (cross-period accounting)
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';
SET LOCAL ROLE service_role;
SELECT set_config('t.p1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000014', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.p1')::uuid, '94780000-0000-0000-0000-000000000014', 'gpt-5.4-mini-2026-03-17', 1200), true, 'reserve in the current UTC period');
RESET ROLE;
SELECT set_config('t.today_company_day', (SELECT micro_usd::text FROM public.catalogue_ai_copy_usage_v1
  WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000'), true);
SELECT set_config('t.today_company_month', (SELECT micro_usd::text FROM public.catalogue_ai_copy_usage_v1
  WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000'), true);
-- Re-home this reservation to the previous UTC day and month, as if the clock rolled over before settlement.
UPDATE public.catalogue_ai_copy_reservations_v1
   SET day_bucket = day_bucket - 1,
       month_bucket = (date_trunc('month', month_bucket::timestamp) - interval '1 month')::date
 WHERE reservation_id = current_setting('t.p1')::uuid;
UPDATE public.catalogue_ai_copy_usage_v1 SET bucket_start = bucket_start - interval '1 day'
 WHERE bucket = 'user_day' AND actor_id = '94780000-0000-0000-0000-000000000014';
INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests, micro_usd) VALUES
  ('company_day', (((now() AT TIME ZONE 'UTC')::date - 1)::timestamp AT TIME ZONE 'UTC'), '00000000-0000-0000-0000-000000000000', 1, 5000000),
  ('company_month', ((date_trunc('month', now() AT TIME ZONE 'UTC') - interval '1 month')::date)::timestamp AT TIME ZONE 'UTC', '00000000-0000-0000-0000-000000000000', 1, 15000);
SET LOCAL ROLE service_role;
SELECT is((public.catalogue_ai_copy_budget_settle_v1(current_setting('t.p1')::uuid, 1000, 500, 'req-roll', 'gpt-5.4-mini-2026-03-17', 'default')->>'charged_micro_usd')::int, 3000, 'settlement after rollover charges verified usage');
RESET ROLE;
SELECT is((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000'
            AND bucket_start = ((date_trunc('month', now() AT TIME ZONE 'UTC') - interval '1 month')::date)::timestamp AT TIME ZONE 'UTC'), 3000::bigint, 'credit went to the ORIGINAL (previous) month');
SELECT is((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000'
            AND bucket_start = (((now() AT TIME ZONE 'UTC')::date - 1)::timestamp AT TIME ZONE 'UTC')), 4988000::bigint, 'credit went to the ORIGINAL (previous) day');
SELECT is((SELECT micro_usd::text FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_day' AND actor_id = '00000000-0000-0000-0000-000000000000'
            AND bucket_start = ((now() AT TIME ZONE 'UTC')::date)::timestamp AT TIME ZONE 'UTC'), current_setting('t.today_company_day'), 'the current day bucket was not touched');
SELECT is((SELECT micro_usd::text FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'company_month' AND actor_id = '00000000-0000-0000-0000-000000000000'
            AND bucket_start = ((date_trunc('month', now() AT TIME ZONE 'UTC'))::date)::timestamp AT TIME ZONE 'UTC'), current_setting('t.today_company_month'), 'the current month bucket was not touched');
-- an exhausted previous day does not carry into the new day
SET LOCAL ROLE service_role;
SELECT set_config('t.p2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000010', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.p2')::uuid, '94780000-0000-0000-0000-000000000010', 'gpt-5.4-mini-2026-03-17', 100), true, 'a new UTC day starts with its own budget (yesterday exhaustion does not carry)');
RESET ROLE;

-- ---------------------------------------------------------------- tripwires trip the emergency latch (disable only)
SET LOCAL ROLE service_role;
SELECT set_config('t.v1', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000011', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.v1')::uuid, '94780000-0000-0000-0000-000000000011', 'gpt-5.4-mini-2026-03-17', 1000), true, 'reservation for the input tripwire');
SELECT is(public.catalogue_ai_copy_budget_settle_v1(current_setting('t.v1')::uuid, 1500, 100, 'req-v1', 'gpt-5.4-mini-2026-03-17', 'default')->>'violation', 'input_exceeds_count', 'provider input above the official count is a violation');
RESET ROLE;
SELECT ok((SELECT emergency_disabled_at IS NOT NULL AND emergency_reason = 'auto:input_exceeds_count' FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'tripwire set the emergency latch');
SELECT is((SELECT charged_micro_usd FROM public.catalogue_ai_copy_reservations_v1 WHERE reservation_id = current_setting('t.v1')::uuid), 1575, 'a violation is charged at verified usage, never below');
SET LOCAL ROLE service_role;
SELECT is(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17'), NULL::uuid, 'latched: gate denies');
RESET ROLE;

UPDATE public.catalogue_ai_copy_budget_policy_v1 SET emergency_disabled_at = NULL, emergency_reason = NULL WHERE singleton;
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';
SET LOCAL ROLE service_role;
SELECT set_config('t.v2', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.v2')::uuid, '94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17', 1000), true, 'reservation for the model tripwire');
SELECT is(public.catalogue_ai_copy_budget_settle_v1(current_setting('t.v2')::uuid, 500, 100, 'req-v2', 'gpt-5.4-mini-fallback', 'default')->>'violation', 'model_mismatch', 'a different response model is a violation');
RESET ROLE;
UPDATE public.catalogue_ai_copy_budget_policy_v1 SET emergency_disabled_at = NULL, emergency_reason = NULL WHERE singleton;
DELETE FROM public.catalogue_ai_copy_usage_v1 WHERE bucket = 'user_minute';
SET LOCAL ROLE service_role;
SELECT set_config('t.v3', coalesce(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17')::text, ''), true);
SELECT is(public.catalogue_ai_copy_budget_reserve_v1(current_setting('t.v3')::uuid, '94780000-0000-0000-0000-000000000012', 'gpt-5.4-mini-2026-03-17', 1000), true, 'reservation for the service-tier tripwire');
SELECT is(public.catalogue_ai_copy_budget_settle_v1(current_setting('t.v3')::uuid, 500, 100, 'req-v3', 'gpt-5.4-mini-2026-03-17', 'priority')->>'violation', 'tier_mismatch', 'a non-default service tier is a violation');
RESET ROLE;

-- emergency disable RPC: sets, is idempotent, and nothing clears it
UPDATE public.catalogue_ai_copy_budget_policy_v1 SET emergency_disabled_at = NULL, emergency_reason = NULL WHERE singleton;
SET LOCAL ROLE service_role;
SELECT set_config('t.e1', public.catalogue_ai_copy_budget_emergency_disable_v1('operator stop')::text, true);
SELECT isnt(current_setting('t.e1'), '', 'emergency disable sets the latch and returns its timestamp');
SELECT is(public.catalogue_ai_copy_budget_emergency_disable_v1('second call')::text, current_setting('t.e1'), 'a second call keeps the original timestamp (idempotent)');
SELECT is(public.catalogue_ai_copy_budget_gate_v1('94780000-0000-0000-0000-000000000001', 'gpt-5.4-mini-2026-03-17'), NULL::uuid, 'manual latch: gate denies');
RESET ROLE;
SELECT is((SELECT emergency_reason FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'operator stop', 'the first reason is kept (idempotent)');

SELECT * FROM finish();
ROLLBACK;
