-- Contract test for migration 20261001193000_final_cert_legacy_rescue_payment_finance_rbac.sql
select plan(9);

select ok(position('FINANCE_HEAD' in upper(pg_get_functiondef(
  'public.guard_order_payment_authority_mutation()'::regprocedure))) > 0,
  'legacy rescue mutation guard requires Finance Head authority');

select ok(position('FINANCE_EXEC' in upper(pg_get_functiondef(
  'public.guard_order_payment_authority_mutation()'::regprocedure))) > 0,
  'legacy rescue mutation guard permits Finance Executive authority');

select ok(position('V_FINANCE_AUTHORITY' in upper(pg_get_functiondef(
  'public.guard_order_payment_authority_mutation()'::regprocedure))) > 0,
  'legacy rescue verification uses an explicit finance-authority predicate');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='order_payments'
  and policyname='Finance update legacy credit rescue payments'
), 'finance-scoped rescue update policy exists');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='order_payments'
  and policyname='Finance delete legacy credit rescue payments'
), 'finance-scoped rescue delete policy exists');

select ok(not exists(
  select 1 from pg_policies where schemaname='public' and tablename='order_payments'
  and policyname='Staff update legacy credit rescue payments'
), 'broad staff rescue update policy is removed');

select ok(not exists(
  select 1 from pg_policies where schemaname='public' and tablename='order_payments'
  and policyname='Staff delete legacy credit rescue payments'
), 'broad staff rescue delete policy is removed');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='order_payments'
  and policyname='Staff insert legacy credit rescue payments'
), 'evidence-upload compatibility remains present');

select ok(position('NEW.STATUS=''UPLOADED''' in replace(upper(pg_get_functiondef(
  'public.guard_order_payment_authority_mutation()'::regprocedure)),' ','')) > 0,
  'legacy compatibility remains evidence-upload only before Finance review');

select * from finish();
