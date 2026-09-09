-- Regression contract for the Point100-discovered E-way runtime ambiguity.

select plan(5);

select has_function(
  'public',
  'record_eway_bill_evidence_v1',
  array['uuid','text','text','text','text','timestamp with time zone','timestamp with time zone','text','text','uuid'],
  'E-way evidence RPC remains present'
);

select ok(
  pg_get_functiondef('public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)'::regprocedure)
    like '%FROM public.final_invoices fi%',
  'E-way RPC aliases final_invoices before reading invoice state'
);

select ok(
  pg_get_functiondef('public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)'::regprocedure)
    like '%fi.id = p_final_invoice_id%fi.status = ''ISSUED''%',
  'E-way RPC qualifies invoice id and status, avoiding RETURNS TABLE status ambiguity'
);

select ok(
  pg_get_functiondef('public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)'::regprocedure)
    like '%assert_finance_clearance_actor_v1%',
  'Finance+AAL2 actor authority remains intact'
);

select ok(
  not has_function_privilege(
    'service_role',
    'public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)',
    'EXECUTE'
  ),
  'service role still cannot impersonate an E-way decision'
);

select * from finish();
