-- CP18 combined integration contract (candidate branch only; NOT part of the three individual PRs).
-- Proves migrations 20261106010000 (Gate scan evidence), 20261106020000 (Finance two-step reversal) and
-- 20261106030000 (production completion) coexist in ONE database: no collision, overload, shadowing, RLS regression or
-- authorization widening. References: b2b_gate_scan_evidence_authority, finance_two_step_reversal_authority,
-- order_item_production_completion_authority.
begin;
select plan(17);

-- 1. every new function exists exactly once (no overload, no shadowing)
select is((select count(*)::int from pg_proc where pronamespace='public'::regnamespace and proname in (
  'record_b2b_dispatch_gate_scan_v1','guard_b2b_gate_scan_insert_v1',
  'request_finance_reversal_v1','decide_finance_reversal_v1','complete_finance_reversal_v1','finance_reversal_snapshot_is_current_v1',
  'complete_order_item_from_production_v1','prevent_order_item_production_completion_mutation')), 8, 'the eight new functions exist exactly once each');
select is((select count(*)::int from pg_proc where pronamespace='public'::regnamespace and proname in (
  'release_b2b_dispatch_carton_at_gate_v1','release_order_to_packed_ready_v1','reverse_finance_control_v1',
  'apply_finance_hold_v1','release_finance_hold_v1','decide_finance_second_approval_v1','complete_3pgs_order_item')), 7, 'replaced and neighbouring functions have no overloads');

-- 2. every SECURITY DEFINER function among them pins search_path
select is((select count(*)::int from pg_proc p where p.pronamespace='public'::regnamespace and p.prosecdef and p.proname in (
  'record_b2b_dispatch_gate_scan_v1','request_finance_reversal_v1','decide_finance_reversal_v1','complete_finance_reversal_v1',
  'complete_order_item_from_production_v1','prevent_order_item_production_completion_mutation',
  'release_b2b_dispatch_carton_at_gate_v1','release_order_to_packed_ready_v1')
  and not exists (select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c where c like 'search_path=%')), 0, 'no SECURITY DEFINER function lacks a pinned search_path');

-- 3. no authorization widening: anon never executes; service_role keeps only what it had
select is((select count(*)::int from unnest(array[
  'public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)','public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)',
  'public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)','public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)',
  'public.complete_order_item_from_production_v1(uuid,text)','public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)',
  'public.release_order_to_packed_ready_v1(uuid)']) f where has_function_privilege('anon', f, 'execute')), 0, 'anon cannot execute any new or replaced function');
select is((select count(*)::int from unnest(array[
  'public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)','public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)',
  'public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)','public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)',
  'public.complete_order_item_from_production_v1(uuid,text)','public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)']) f where has_function_privilege('service_role', f, 'execute')), 0, 'service_role cannot execute them (unchanged from the prior release grants)');
select ok(has_function_privilege('service_role','public.release_order_to_packed_ready_v1(uuid)','execute'), 'release_order_to_packed_ready_v1 keeps its previous service_role grant (no widening, no narrowing)');
select is((select count(*)::int from unnest(array[
  'public.finance_reversal_snapshot_is_current_v1(uuid)','public.prevent_order_item_production_completion_mutation()']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'internal helpers are not callable by clients');

-- 4. RLS and table privileges
select ok((select relrowsecurity from pg_class where oid='public.order_item_production_completions'::regclass)
      and (select relrowsecurity from pg_class where oid='public.order_production_evidence_policy'::regclass), 'new tables have RLS enabled');
select ok(not has_table_privilege('authenticated','public.order_item_production_completions','insert')
      and not has_table_privilege('authenticated','public.order_production_evidence_policy','update')
      and not has_table_privilege('authenticated','public.finance_control_events','insert'), 'clients cannot write completion events, the policy row or Finance control events directly');
select ok(exists(select 1 from pg_class where oid='public.finance_control_events'::regclass and relrowsecurity), 'finance_control_events RLS is unchanged');

-- 5. existing immutability and append-only guards survive
select ok((select count(*)::int from pg_trigger where tgrelid='public.operational_scan_records'::regclass and not tgisinternal
  and tgname in ('trg_operational_scan_records_no_update','trg_operational_scan_records_no_delete','trg_operational_scan_records_gate_authority'))=3, 'scan evidence keeps append-only triggers and gains the authority guard');
select ok(exists(select 1 from pg_trigger where tgrelid='public.finance_control_events'::regclass and tgname='trg_finance_control_events_immutable' and not tgisinternal), 'Finance control events stay immutable');
select ok(exists(select 1 from pg_trigger where tgrelid='public.order_item_production_completions'::regclass and tgname='trg_order_item_production_completions_immutable' and not tgisinternal), 'completion events are immutable');

-- 6. cross-migration wiring
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) like '%B2B_GATE_SCAN_V1%'
      and pg_get_functiondef('public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)'::regprocedure) like '%B2B_GATE_SCAN_V1%', 'Gate release and the Gate scan writer agree on the authority marker');
select ok(pg_get_functiondef('public.release_order_to_packed_ready_v1(uuid)'::regprocedure) like '%order_item_production_completions%', 'packed-ready consults the completion events');
select ok((select enforce_packed_ready from public.order_production_evidence_policy)=false, 'production evidence policy remains in observe mode');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.finance_control_events'::regclass and contype='c' and pg_get_constraintdef(oid) like '%control_kind%') like '%SECOND_APPROVAL%REVERSAL_REQUEST%', 'the widened Finance constraint keeps every original kind');

-- 7. fingerprint of the combined contract surface (diagnostic, printed in the CI log)
select diag('CP18 combined contract fingerprint: ' || (select md5(string_agg(pg_get_functiondef(p.oid), E'\n' order by p.proname)) from pg_proc p
  where p.pronamespace='public'::regnamespace and p.proname in (
  'record_b2b_dispatch_gate_scan_v1','guard_b2b_gate_scan_insert_v1','request_finance_reversal_v1','decide_finance_reversal_v1',
  'complete_finance_reversal_v1','finance_reversal_snapshot_is_current_v1','complete_order_item_from_production_v1',
  'release_b2b_dispatch_carton_at_gate_v1','release_order_to_packed_ready_v1')));
select * from finish();
rollback;
