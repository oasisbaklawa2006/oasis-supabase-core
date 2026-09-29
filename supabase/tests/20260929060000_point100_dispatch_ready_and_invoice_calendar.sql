begin;
select plan(10);

select has_function(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  array['uuid','text'],
  'Point100 carton readiness authority exists'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)',
    'EXECUTE'
  ),
  'authenticated staff may execute carton readiness authority'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)',
    'EXECUTE'
  ),
  'anon cannot execute carton readiness authority'
);

select ok(
  not has_function_privilege(
    'service_role',
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass user-session carton readiness authority'
);

select like(
  pg_get_functiondef(
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)'::regprocedure
  ),
  '%v_carton.status <> ''locked''%',
  'carton readiness transition only originates from locked'
);

select like(
  pg_get_functiondef(
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)'::regprocedure
  ),
  '%assert_active_dispatch_clearance_v1%',
  'carton readiness requires active Finance dispatch clearance'
);

select like(
  pg_get_functiondef(
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)'::regprocedure
  ),
  '%finance_dpl_receipts%',
  'carton readiness is bound to Finance DPL truth'
);

select like(
  pg_get_functiondef(
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,text)'::regprocedure
  ),
  '%b2b_dispatch_events%',
  'carton readiness writes governed dispatch event evidence'
);

select ok(
  (
    select coalesce(array_to_string(p.proconfig, ','), '')
      from pg_proc p
     where p.oid = 'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure
  ) like '%TimeZone=Asia/Kolkata%',
  'final invoice authority uses Asia/Kolkata business date'
);

select ok(
  (
    select prosecdef
      from pg_proc
     where oid = 'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure
  ),
  'final invoice authority remains SECURITY DEFINER'
);

select * from finish();
rollback;
