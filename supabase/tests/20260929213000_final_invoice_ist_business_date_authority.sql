-- Contract test for migration 20260929213000_final_invoice_ist_business_date_authority.sql
begin;

select plan(5);

select has_function(
  'public',
  'issue_final_invoice_v1',
  array['uuid','uuid','uuid','uuid','text','date','text','text','text','text','uuid'],
  'final invoice authority exists'
);

select ok(
  position(
    'p_invoice_date > (statement_timestamp() at time zone ''asia/kolkata'')::date'
    in lower(pg_get_functiondef(
      'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure
    ))
  ) > 0,
  'final invoice future-date guard uses the Asia/Kolkata statement date'
);

select ok(
  position(
    'p_invoice_date > current_date'
    in lower(pg_get_functiondef(
      'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure
    ))
  ) = 0,
  'final invoice no longer compares invoice date to UTC current_date'
);

select is(
  (timestamptz '2026-09-29 19:00:00+00' at time zone 'Asia/Kolkata')::date
    > (timestamptz '2026-09-29 19:00:00+00')::date,
  true,
  'Kolkata business date can advance before the UTC calendar date'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)',
    'EXECUTE'
  ),
  'final invoice execution privileges remain authenticated-only'
);

select * from finish();
rollback;
