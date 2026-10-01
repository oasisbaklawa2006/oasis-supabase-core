-- Contract test for migration 20261001183000_final_cert_production_department_rbac_hardening.sql
-- Regression contract for final-certification production RBAC hardening.
select plan(12);

select has_function('public','dispatch_production_to_rgs',array['uuid','numeric','text','text'],
  'dispatch_production_to_rgs exists');
select has_function('public','report_production_issue',array['uuid','text','text','text','text','text'],
  'report_production_issue exists');
select has_function('public','resolve_production_issue',array['uuid','text'],
  'resolve_production_issue exists');

select function_returns('public','dispatch_production_to_rgs',array['uuid','numeric','text','text'],'production_rgs_transfers',
  'dispatch transfer return type preserved');
select function_returns('public','report_production_issue',array['uuid','text','text','text','text','text'],'production_issues',
  'report issue return type preserved');
select function_returns('public','resolve_production_issue',array['uuid','text'],'production_issues',
  'resolve issue return type preserved');

select ok(position('ROLE_CANONICAL_DEPARTMENT' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch transfer enforces actor department');
select ok(position('ACTOR IS NOT AUTHORISED FOR DEPARTMENT' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch transfer fails cross-department actors closed');

select ok(position('ROLE_CANONICAL_DEPARTMENT' in upper(pg_get_functiondef(
  'public.report_production_issue(uuid,text,text,text,text,text)'::regprocedure))) > 0,
  'issue reporting enforces actor department');
select ok(position('ACTOR IS NOT AUTHORISED FOR DEPARTMENT' in upper(pg_get_functiondef(
  'public.report_production_issue(uuid,text,text,text,text,text)'::regprocedure))) > 0,
  'issue reporting fails cross-department actors closed');

select ok(position('ROLE_CANONICAL_DEPARTMENT' in upper(pg_get_functiondef(
  'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0,
  'issue resolution enforces actor department');
select ok(position('ACTOR IS NOT AUTHORISED FOR DEPARTMENT' in upper(pg_get_functiondef(
  'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0,
  'issue resolution fails cross-department actors closed');

select * from finish();
