-- Contract for 20260901003000_invoice_date_complaint_window_authority.sql.

select plan(15);

select has_function(
  'public','complaint_deadline_from_invoice_v1',array['date'],
  'canonical invoice-date complaint deadline helper exists'
);
select is(
  public.complaint_deadline_from_invoice_v1(date '2026-09-01'),
  timestamptz '2026-09-10 18:30:00+00',
  'invoice date is Day 1; expiry is start of Day 11 in Asia/Kolkata'
);
select ok(
  pg_get_functiondef('public.complaint_deadline_from_invoice_v1(date)'::regprocedure) like '%Asia/Kolkata%',
  'deadline uses the business timezone explicitly'
);
select ok(
  pg_get_functiondef('public.complaint_deadline_from_invoice_v1(date)'::regprocedure) like '%interval ''10 days''%',
  'deadline spans ten inclusive invoice calendar days'
);
select ok(
  pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure)
    like '%complaint_deadline_from_invoice_v1(v_invoice.invoice_date)%',
  'delivery proof reports the existing invoice-based deadline'
);
select ok(
  pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure)
    not like '%v_existing.delivered_at + interval ''10 days''%',
  'delivery time cannot start or extend the complaint clock'
);
select ok(
  pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure)
    like '%COMPLAINT_FINAL_INVOICE_REQUIRED%',
  'ticket intake requires canonical final-invoice lineage'
);
select ok(
  regexp_replace(
    pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure),
    '[[:space:]]+','','g'
  ) like '%v_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date)%',
  'ticket eligibility derives its deadline from final invoice date'
);
select ok(
  regexp_replace(
    pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure),
    '[[:space:]]+','','g'
  ) like '%statement_timestamp()>=v_deadline%',
  'ticket window expires exactly at the exclusive start-of-Day-11 deadline'
);
select ok(
  pg_get_functiondef('public.get_commercial_complaint_window_rows_v1()'::regprocedure)
    like '%complaint_deadline_from_invoice_v1%',
  'complaint-window authority is anchored to the canonical invoice deadline helper'
);
select ok(
  (select definition from pg_views where schemaname='public' and viewname='commercial_complaint_window_v1')
    like '%get_commercial_complaint_window_rows_v1%',
  'buyer-facing complaint-window view delegates to the scoped canonical helper'
);
select ok(
  pg_get_functiondef('public.get_commercial_complaint_window_rows_v1()'::regprocedure)
    not like '%delivered_at +%',
  'complaint-window authority does not derive deadline from delivery'
);
select ok(
  pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure)
    like '%FINAL_INVOICE_DATE%',
  'Finance/Exit facts declare the complaint clock basis'
);
select ok(
  pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure)
    like '%complaint_deadline_from_invoice_v1(v_invoice.invoice_date)%',
  'Finance/Exit facts expose the same invoice-derived deadline'
);
select ok(
  has_function_privilege('authenticated','public.complaint_deadline_from_invoice_v1(date)','EXECUTE'),
  'authenticated governed callers can read the canonical deadline helper'
);

select * from finish();
