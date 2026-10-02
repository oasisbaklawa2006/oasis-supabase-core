-- Contract test for migration 20261003001000_final_cert_production_department_rbac_hardening.sql
-- Regression contract for final-certification production RBAC hardening.
select plan(18);

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

select ok(position('IS_INVENTORY_RECEIVE_ROLE' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch transfer preserves governed RGS receiving-role handoff authority');

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

select ok(
  position('V_JOB_CANONICAL_DEPARTMENT IS NULL' in upper(pg_get_functiondef(
    'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0
  and position('ROLE_CANONICAL_DEPARTMENT(V_ACTOR_ROLE) IS NULL' in upper(pg_get_functiondef(
    'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0,
  'issue resolution fails NULL/unmapped job or actor department closed'
);

select ok(position('IS NOT TRUE' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch transfer internal-staff check fails NULL closed');

select ok(position('CORRELATION ID ALREADY USED FOR A DIFFERENT JOB' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch replay is bound to the requested job');

select ok(position('CANONICAL_DEPARTMENT IS NULL' in upper(pg_get_functiondef(
  'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch transfer rejects null job department unless governed override applies');

select ok(position('JOB_ID = P_JOB_ID' in upper(pg_get_functiondef(
  'public.report_production_issue(uuid,text,text,text,text,text)'::regprocedure))) > 0,
  'issue replay is bound to the requested job');

select * from finish();
