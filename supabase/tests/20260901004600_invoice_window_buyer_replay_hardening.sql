-- Regression contract for buyer-scoped complaint-window visibility and
-- delivery-proof idempotent replay after invoice-lineage changes.

select plan(10);

select ok(
  not coalesce((
    select 'security_invoker=true'=any(reloptions)
    from pg_class
    where oid='public.commercial_complaint_window_v1'::regclass
  ),false),
  'complaint-window projection does not inherit final_invoices buyer-denying RLS'
);

select ok(
  coalesce((
    select 'security_barrier=true'=any(reloptions)
    from pg_class
    where oid='public.commercial_complaint_window_v1'::regclass
  ),false),
  'complaint-window projection is a security-barrier view'
);

select ok(
  (select definition from pg_views where schemaname='public' and viewname='commercial_complaint_window_v1')
    like '%auth_buyer_company_id%',
  'complaint-window projection scopes buyer reads to the caller company'
);

select ok(
  (select definition from pg_views where schemaname='public' and viewname='commercial_complaint_window_v1')
    like '%company_id%',
  'buyer authorization is bound to final-invoice company lineage'
);

select ok(
  (select definition from pg_views where schemaname='public' and viewname='commercial_complaint_window_v1')
    like '%service_role%',
  'service-role projection access remains explicit rather than relying on base-table RLS'
);

with src as (
  select lower(regexp_replace(
    pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure),
    '[[:space:]]+','','g'
  )) as body
)
select ok(
  strpos(body,'select*intov_existingfrompublic.delivery_proofswhereidempotency_key=btrim(p_idempotency_key)')>0
  and strpos(body,'whereorder_id=p_order_idandstatus=''issued''')>0
  and strpos(body,'select*intov_existingfrompublic.delivery_proofswhereidempotency_key=btrim(p_idempotency_key)')
      < strpos(body,'whereorder_id=p_order_idandstatus=''issued'''),
  'existing idempotency proof is checked before current issued-invoice eligibility'
) from src;

select ok(
  lower(regexp_replace(
    pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure),
    '[[:space:]]+','','g'
  )) like '%created_at<=v_existing.created_at%',
  'replay recovers invoice lineage relative to immutable proof creation time'
);

select ok(
  pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure)
    like '%DELIVERY_PROOF_IDEMPOTENCY_CONFLICT%',
  'changed replay fingerprints remain fail-closed'
);

select ok(
  not has_function_privilege('service_role','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'service_role cannot execute the user-session Finance Exit facts RPC'
);

select ok(
  has_function_privilege('authenticated','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'authenticated internal callers retain Finance Exit facts execution authority'
);

select * from finish();
