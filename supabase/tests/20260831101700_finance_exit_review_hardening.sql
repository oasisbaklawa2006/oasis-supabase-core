-- Contract for migration 20260831101700_finance_exit_review_hardening.sql.
select plan(12);

select ok(
  pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%B2B_FINANCE_DPL_CURRENT_VERSION_AMBIGUOUS%',
  'Finance DPL receipt fails closed on duplicate current submitted DPLs'
);
select ok(
  pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%HAVING count(*)<>1%',
  'current submitted DPL cardinality is explicitly checked per consignment'
);
select ok(
  pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%SELECT DISTINCT bc.id carton_id%',
  'Finance snapshot de-duplicates carton identity defensively'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%carton_not_ready_for_gate%',
  'gate returns governed blocker for invalid carton state'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%status NOT IN(''ready_to_load'',''loaded'')%',
  'gate only accepts ready-to-load or loaded cartons'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%carton_lock_evidence_incomplete%',
  'gate returns governed blocker for missing carton lock evidence'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%open_photo_ref IS NULL%locked_by IS NULL%locked_at IS NULL%',
  'gate validates required lock evidence before handover'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%physical_location = ''LOADED''%' OR
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    like '%physical_location=''LOADED''%',
  'handover records loaded physical location'
);
select ok(
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    not like '%physical_location = ''READY_TO_LOAD_BAY''%' AND
  pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure)
    not like '%physical_location=''READY_TO_LOAD_BAY''%',
  'handover no longer records pre-handover bay location'
);
select ok(
  not has_function_privilege('service_role','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'service_role is not granted an RPC that requires a user-session actor'
);
select ok(
  has_function_privilege('authenticated','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'authenticated internal callers retain Finance Exit facts access'
);
select ok(
  pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%FINANCE_EXIT_FACTS_INTERNAL_ONLY%',
  'Finance Exit facts remains internal-staff fail-closed'
);

select * from finish();
