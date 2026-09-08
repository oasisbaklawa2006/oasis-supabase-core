-- Contract for 20260908020000_macro_dispatch_finalization_authority.sql
begin;
select plan(12);

select has_function(
  'public',
  'release_order_to_dispatched_v1',
  array['uuid','text','text','text','text'],
  'canonical order dispatch finalizer exists'
);

select ok(
  (select prosecdef from pg_proc where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure),
  'dispatch finalizer is SECURITY DEFINER'
);

select ok(
  has_function_privilege('authenticated', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE'),
  'authenticated internal operators can call governed dispatch finalization'
);

select ok(
  not has_function_privilege('anon', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE'),
  'anonymous, PUBLIC and detached service-role execution are denied'
);

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%auth.uid()%'
    and pg_get_functiondef(oid) like '%is_internal_staff%'
    and pg_get_functiondef(oid) like '%DISPATCH_FINALIZATION_ACTOR_REQUIRED%'
$$, 'dispatch finalization binds the authenticated internal actor');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%assert_order_transition_role(''gate_release'')%'
$$, 'dispatch finalization reuses the canonical physical-exit role boundary');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%FROM public.dispatch_proof_packets%'
    and pg_get_functiondef(oid) like '%dispatch_proof_required%'
$$, 'immutable post-gate dispatch proof is mandatory');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%assert_active_dispatch_clearance_v1%'
    and pg_get_functiondef(oid) like '%finance_dispatch_clearance_required%'
$$, 'active Finance dispatch clearance is revalidated at finalization time');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%tracking_reference%'
    and pg_get_functiondef(oid) like '%lr_awb_bilty%'
    and pg_get_functiondef(oid) like '%transporter%'
    and pg_get_functiondef(oid) like '%tracking_reference_mismatch%'
    and pg_get_functiondef(oid) like '%courier_mismatch%'
$$, 'optional caller transport fields validate against frozen proof rather than replacing it');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%cleared_for_dispatch%'
    and pg_get_functiondef(oid) like '%invalid_status%'
    and pg_get_functiondef(oid) like '%already_applied%'
$$, 'only cleared_for_dispatch advances and dispatched replay is idempotent');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%UPDATE public.orders%'
    and pg_get_functiondef(oid) like '%SET status = ''dispatched''%'
    and pg_get_functiondef(oid) like '%INSERT INTO public.order_status_history%'
$$, 'finalizer atomically writes the canonical order state and status history');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%INSERT INTO public.audit_logs%'
    and pg_get_functiondef(oid) like '%ORDER_DISPATCHED%'
    and pg_get_functiondef(oid) like '%dispatch_proof_fingerprint%'
    and pg_get_functiondef(oid) like '%finance_dispatch_clearance_event_id%'
$$, 'high-risk dispatch audit is bound to canonical proof and Finance clearance');

select * from finish();
rollback;
