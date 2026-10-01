-- Contract for migration 20261001220000_gate_dispatch_role_separation.sql.
begin;
select plan(10);

select has_function('public','assert_order_transition_role',array['text'],
  'canonical order transition role guard exists');

select ok(
  pg_get_functiondef('public.assert_order_transition_role(text)'::regprocedure)
    like '%p_action=''gate_release'' and v_role not in (''SECURITY_CONTROL'',''GATE_SECURITY'',''ADMIN'',''SUPER_ADMIN'',''OWNER'')%',
  'gate_release is restricted to independent Security Gate plus governed admin override'
);

select ok(
  pg_get_functiondef('public.assert_order_transition_role(text)'::regprocedure)
    like '%p_action=''dispatch_proof'' and v_role not in (''DISPATCH_HEAD'',''DISPATCH_MANAGER'',''DISPATCH_INCHARGE'',''ADMIN'',''SUPER_ADMIN'',''OWNER'')%',
  'dispatch proof has its own Dispatch authority'
);

select ok(
  pg_get_functiondef('public.assert_order_transition_role(text)'::regprocedure)
    like '%p_action=''dispatch_finalize'' and v_role not in (''DISPATCH_HEAD'',''DISPATCH_MANAGER'',''DISPATCH_INCHARGE'',''ADMIN'',''SUPER_ADMIN'',''OWNER'')%',
  'dispatch finalization has its own Dispatch authority'
);

select ok(
  pg_get_functiondef('public.assert_order_transition_role(text)'::regprocedure)
    like '%p_action=''delivery_proof'' and v_role not in (''DISPATCH_HEAD'',''DISPATCH_MANAGER'',''DISPATCH_INCHARGE'',''ADMIN'',''SUPER_ADMIN'',''OWNER'')%',
  'delivery proof has its own Dispatch authority'
);

select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%assert_order_transition_role(''gate_release'')%',
  'B2B carton exit remains bound to independent gate authority'
);

select ok(
  pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure)
    like '%assert_order_transition_role(''dispatch_proof'')%',
  'dispatch proof no longer reuses gate authority'
);

select ok(
  pg_get_functiondef('public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure)
    like '%assert_order_transition_role(''dispatch_finalize'')%',
  'order dispatch finalization no longer reuses gate authority'
);

select ok(
  pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure)
    like '%assert_order_transition_role(''delivery_proof'')%',
  'delivery proof no longer reuses gate authority'
);

select ok(
  (select relrowsecurity from pg_class where oid='public.b2b_dispatch_gate_decisions'::regclass)
  and exists(
    select 1 from pg_trigger
    where tgrelid='public.b2b_dispatch_gate_decisions'::regclass
      and tgname='trg_b2b_dispatch_gate_decisions_immutable'
      and not tgisinternal
  ),
  'B2B gate decision evidence remains RLS-protected and immutable'
);

select * from finish();
rollback;
