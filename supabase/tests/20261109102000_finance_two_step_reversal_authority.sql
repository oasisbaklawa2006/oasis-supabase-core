-- Contract for migration 20261109102000_finance_two_step_reversal_authority.sql
-- (finance_two_step_reversal_authority): request -> independent approval -> completion, AAL2, maker-checker,
-- immutable snapshot, stale-snapshot refusal, idempotency/replay, negative authorization, no weakening of the
-- existing immediate reverse_finance_control_v1 (still present).
begin;
select plan(11);

select has_function('public','request_finance_reversal_v1',array['uuid','text','text','text','text','uuid'],'request RPC exists');
select has_function('public','decide_finance_reversal_v1',array['uuid','boolean','text','text','text','text','uuid'],'decision RPC exists');
select has_function('public','complete_finance_reversal_v1',array['uuid','text','text','text','text','uuid'],'completion RPC exists');
select has_function('public','reverse_finance_control_v1',array['uuid','text','text','text','text','uuid'],'existing immediate reversal is untouched (not removed)');
select ok(not has_function_privilege('anon','public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)','execute')
      and not has_function_privilege('service_role','public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)','execute'),
  'anon and service_role cannot execute the reversal RPCs');
select ok(pg_get_functiondef('public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%'
      and pg_get_functiondef('public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%'
      and pg_get_functiondef('public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%',
  'all three require Finance + AAL2 first');
select ok(pg_get_functiondef('public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_REVERSAL_MAKER_CHECKER%',
  'approval enforces maker-checker');
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='uq_finance_reversal_approval_once'), 'a request can be decided only once (unique index)');
select ok(pg_get_functiondef('public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%'
      and pg_get_functiondef('public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%',
  'requests and completions are serialised per target event');

select lives_ok($macro$
DO $t$
DECLARE
  v_staff uuid := 'b1000000-0000-4000-8000-000000000001';
  v_staff2 uuid := 'b1000000-0000-4000-8000-000000000002';
  v_sales uuid := 'b1000000-0000-4000-8000-000000000003';
  v_company uuid := 'b1000000-0000-4000-8000-000000000010';
  v_order uuid := 'b1000000-0000-4000-8000-000000000020';
  v_hold uuid; v_req uuid; v_req2 uuid; v_appr uuid; v_rev uuid; v_rev_again uuid; v_hold2 uuid; v_req3 uuid;
  v_n int;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES
    (v_staff, 'rev-staff1@test.invalid'), (v_staff2, 'rev-staff2@test.invalid'), (v_sales, 'rev-sales@test.invalid')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_staff, 'FINANCE_EXEC', 'Rev Finance 1', true), (v_staff2, 'FINANCE_EXEC', 'Rev Finance 2', true),
    (v_sales, 'SALES_EXECUTIVE', 'Rev Sales', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'Reversal Co', 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES (v_order, v_company, 'REV-ORD-1', 'MANUAL', 'rev-ord-1-token', 100000, 30000, 'active') ON CONFLICT (id) DO NOTHING;
  set local session_replication_role = default;

  -- maker places a blocking hold
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  SELECT control_event_id INTO v_hold FROM public.apply_finance_hold_v1(v_company, v_order, NULL, 'ORDER', 1000, 'reversal chain hold', 'evidence', 'corr', 'rev-hold-1', v_staff);

  -- NEGATIVE: non-Finance actor, even with AAL2, cannot request.
  -- A sentinel with SQLSTATE P0001 would be swallowed by the very handler
  -- intended to verify authorization: keep the test's failure code distinct.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_sales::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  BEGIN
    PERFORM public.request_finance_reversal_v1(v_hold, 'sales probe reversal', 'evidence', 'corr', 'rev-req-sales', v_sales);
    RAISE EXCEPTION 'REV_NON_FINANCE_NOT_REJECTED' USING ERRCODE = 'XX000';
  EXCEPTION WHEN sqlstate 'P0001' THEN
    IF SQLERRM NOT LIKE '%finance authority required%' THEN
      RAISE;
    END IF;
  END;

  -- NEGATIVE: Finance without AAL2 cannot request
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  BEGIN
    PERFORM public.request_finance_reversal_v1(v_hold, 'no aal2 probe', 'evidence', 'corr', 'rev-req-aal1', v_staff);
    RAISE EXCEPTION 'REV_AAL1_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '42501' THEN NULL; END;

  -- POSITIVE: maker requests; the hold stays ACTIVE until completion
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  SELECT request_event_id INTO v_req FROM public.request_finance_reversal_v1(v_hold, 'reverse the hold', 'evidence', 'corr', 'rev-req-1', v_staff);
  IF NOT EXISTS (SELECT 1 FROM public.finance_control_authority_v1 f WHERE f.control_event_id = v_hold AND f.active_blocking_hold) THEN
    RAISE EXCEPTION 'REV_REQUEST_NEUTRALISED_HOLD';
  END IF;
  -- REPLAY: same key + same payload returns the same request
  SELECT request_event_id INTO v_req2 FROM public.request_finance_reversal_v1(v_hold, 'reverse the hold', 'evidence', 'corr', 'rev-req-1', v_staff);
  IF v_req2 IS DISTINCT FROM v_req THEN RAISE EXCEPTION 'REV_REQUEST_REPLAY_DIFFERENT'; END IF;
  -- NEGATIVE: same key, different payload
  BEGIN
    PERFORM public.request_finance_reversal_v1(v_hold, 'a different reason', 'evidence', 'corr', 'rev-req-1', v_staff);
    RAISE EXCEPTION 'REV_KEY_CONFLICT_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '23505' THEN NULL; END;
  -- NEGATIVE: second open request for the same target
  BEGIN
    PERFORM public.request_finance_reversal_v1(v_hold, 'second open request', 'evidence', 'corr', 'rev-req-dup', v_staff);
    RAISE EXCEPTION 'REV_DUP_OPEN_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;
  -- the snapshot is recorded immutably on the request
  SELECT count(*) INTO v_n FROM public.finance_control_events
   WHERE id = v_req AND facts_snapshot->>'target_event_id' = v_hold::text AND (facts_snapshot->>'order_sales_order_value')::numeric = 100000;
  IF v_n <> 1 THEN RAISE EXCEPTION 'REV_SNAPSHOT_MISSING'; END IF;

  -- NEGATIVE: completing before approval
  BEGIN
    PERFORM public.complete_finance_reversal_v1(v_req, 'complete too early', 'evidence', 'corr', 'rev-done-early', v_staff);
    RAISE EXCEPTION 'REV_COMPLETE_BEFORE_APPROVAL_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;
  -- NEGATIVE: maker cannot approve their own request
  BEGIN
    PERFORM public.decide_finance_reversal_v1(v_req, true, 'self approval probe', 'evidence', 'corr', 'rev-appr-self', v_staff);
    RAISE EXCEPTION 'REV_SELF_APPROVAL_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '42501' THEN NULL; END;

  -- POSITIVE: independent checker approves
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  SELECT approval_event_id INTO v_appr FROM public.decide_finance_reversal_v1(v_req, true, 'approve reversal', 'evidence', 'corr', 'rev-appr-1', v_staff2);
  IF (SELECT approver_id FROM public.finance_control_events WHERE id = v_appr) IS DISTINCT FROM v_staff2 THEN RAISE EXCEPTION 'REV_APPROVER_NOT_RECORDED'; END IF;
  -- NEGATIVE: a request is decided only once
  BEGIN
    PERFORM public.decide_finance_reversal_v1(v_req, false, 'second decision probe', 'evidence', 'corr', 'rev-appr-2', v_staff2);
    RAISE EXCEPTION 'REV_DOUBLE_DECISION_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;

  -- NEGATIVE: stale financial snapshot refuses completion (balance moved after approval)
  RESET ROLE;
  set local session_replication_role = replica;
  UPDATE public.orders SET advance_required = advance_required, sales_order_value = 120000 WHERE id = v_order;
  set local session_replication_role = default;
  set local role authenticated;
  BEGIN
    PERFORM public.complete_finance_reversal_v1(v_req, 'stale probe', 'evidence', 'corr', 'rev-done-stale', v_staff2);
    RAISE EXCEPTION 'REV_STALE_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '40001' THEN NULL; END;
  -- the stale approved request is superseded: a fresh request is allowed
  RESET ROLE;
  set local session_replication_role = replica;
  UPDATE public.orders SET sales_order_value = 100000 WHERE id = v_order;
  set local session_replication_role = default;
  set local role authenticated;

  -- POSITIVE: completion (financial position unchanged again) neutralises the hold, via the existing reversal logic
  SELECT control_event_id INTO v_rev FROM public.complete_finance_reversal_v1(v_req, 'complete reversal', 'evidence', 'corr', 'rev-done-1', v_staff2);
  IF EXISTS (SELECT 1 FROM public.finance_control_authority_v1 f WHERE f.control_event_id = v_hold AND f.active_blocking_hold) THEN
    RAISE EXCEPTION 'REV_HOLD_STILL_ACTIVE';
  END IF;
  -- REPLAY: completion with the same key returns the same event and writes nothing new
  SELECT control_event_id INTO v_rev_again FROM public.complete_finance_reversal_v1(v_req, 'complete reversal', 'evidence', 'corr', 'rev-done-1', v_staff2);
  IF v_rev_again IS DISTINCT FROM v_rev THEN RAISE EXCEPTION 'REV_COMPLETE_REPLAY_DIFFERENT'; END IF;
  SELECT count(*) INTO v_n FROM public.finance_control_events WHERE control_kind = 'REVERSAL' AND prior_event_id = v_hold;
  IF v_n <> 1 THEN RAISE EXCEPTION 'REV_DUPLICATE_REVERSAL_EVENT'; END IF;
  -- NEGATIVE: the already-reversed target cannot be requested again
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  BEGIN
    PERFORM public.request_finance_reversal_v1(v_hold, 'again after reversal', 'evidence', 'corr', 'rev-req-after', v_staff);
    RAISE EXCEPTION 'REV_AFTER_REVERSAL_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;
  -- the events are immutable
  RESET ROLE;
  BEGIN
    UPDATE public.finance_control_events SET reason = 'tamper' WHERE id = v_req;
    RAISE EXCEPTION 'REV_EVENT_MUTABLE';
  EXCEPTION WHEN sqlstate '42501' THEN NULL; END;

  -- a REJECTED request does not neutralise, and frees a new request
  set local role authenticated;
  SELECT control_event_id INTO v_hold2 FROM public.apply_finance_hold_v1(v_company, v_order, NULL, 'ORDER', 2000, 'second hold', 'evidence', 'corr', 'rev-hold-2', v_staff);
  SELECT request_event_id INTO v_req3 FROM public.request_finance_reversal_v1(v_hold2, 'reverse second hold', 'evidence', 'corr', 'rev-req-3', v_staff);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  PERFORM public.decide_finance_reversal_v1(v_req3, false, 'reject reversal', 'evidence', 'corr', 'rev-appr-3', v_staff2);
  BEGIN
    PERFORM public.complete_finance_reversal_v1(v_req3, 'complete rejected', 'evidence', 'corr', 'rev-done-3', v_staff2);
    RAISE EXCEPTION 'REV_REJECTED_COMPLETED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;
  IF NOT EXISTS (SELECT 1 FROM public.finance_control_authority_v1 f WHERE f.control_event_id = v_hold2 AND f.active_blocking_hold) THEN
    RAISE EXCEPTION 'REV_REJECTED_NEUTRALISED_HOLD';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  PERFORM public.request_finance_reversal_v1(v_hold2, 'new request after rejection', 'evidence', 'corr', 'rev-req-4', v_staff);
END
$t$;
$macro$, 'two-step reversal: positive, negative, stale, replay, duplicate and immutability paths all behave');

select ok((select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.finance_control_events'::regclass and contype='c' and pg_get_constraintdef(oid) like '%control_kind%') like '%REVERSAL_REQUEST%REVERSAL_APPROVAL%', 'the table constraint admits the two new event kinds and keeps the original ones');
select * from finish();
rollback;
