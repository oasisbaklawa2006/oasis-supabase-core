BEGIN;
SELECT plan(14);

SELECT pass('20260929123000_b2b_dispatch_carton_ready_to_load_authority.sql contract');

SELECT has_function(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'ready-to-load transition RPC exists'
);

SELECT function_lang_is(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'plpgsql',
  'ready-to-load RPC uses plpgsql'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'anon',
  ARRAY[]::text[],
  'anon cannot execute ready-to-load transition'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'service_role',
  ARRAY[]::text[],
  'service_role cannot bypass authenticated actor boundary'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'authenticated',
  ARRAY['EXECUTE'],
  'authenticated may invoke governed transition'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%can_manage_b2b_dispatch%',
  'RPC enforces Dispatch authority'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%assert_active_dispatch_clearance_v1%',
  'RPC requires active Finance Dispatch Clearance'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%final_invoices%',
  'RPC requires issued final invoice'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%finance_dpl_receipts%',
  'RPC requires governed final DPL'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%eway_bill_evidence%',
  'RPC requires E-way evidence'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%current_version = p_expected_version%',
  'RPC enforces optimistic concurrency'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%carton_ready_to_load%',
  'RPC records an audit event'
);

SELECT unlike(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%GRANT%service_role%',
  'RPC body contains no service-role bypass'
);

SELECT * FROM finish();
ROLLBACK;
