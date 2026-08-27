begin;
-- Contract coverage for 20260822160000_production_issue_resolution_and_escalation.sql.
select plan(27);

select has_function('public', 'report_production_issue', 'report_production_issue exists');
select has_function('public', 'resolve_production_issue', 'resolve_production_issue exists');
select has_column('public', 'production_issues', 'status', 'production_issues has a status column');
select has_column('public', 'production_issues', 'resolved_by', 'production_issues has a resolved_by column');
select has_column('public', 'production_issues', 'resolved_at', 'production_issues has a resolved_at column');

insert into public.users (id, role) values
  ('99d00000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('99d00000-0000-0000-0000-000000000002', 'B2B_BUYER');

insert into public.orders (id, order_number, tracking_token, order_origin)
values ('99d30000-0000-0000-0000-000000000001', 'PGTAP-PRODISSUE-ORD-1', 'pgtap-prodissue-token-1', 'MANUAL');

insert into public.products (id, name, category, sku, hsn_code)
values ('99d40000-0000-0000-0000-000000000001', 'Prod Issue Test Tray', 'sweets', 'PRODISSUE-TRAY-1', '1905');

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty)
values ('99d50000-0000-0000-0000-000000000001', '99d30000-0000-0000-0000-000000000001', '99d40000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10);

set local request.jwt.claim.role = 'authenticated';

-- 1: unauthorised caller (non-staff) is rejected.
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'ARABIC_SWEETS', 'machine', 'Mixer broken', null, 'pgtap-issue-1')$$,
  'Not authorised to report a production issue', 'a non-staff role cannot report a production issue'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';

-- 2: an invalid issue_type is rejected.
select throws_ok(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'ARABIC_SWEETS', 'sabotage', 'nonsense', null, 'pgtap-issue-bad-type')$$,
  'issue_type must be one of material, machine, delay', 'an invalid issue_type is rejected'
);

-- 3: a blank comment is rejected.
select throws_ok(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'ARABIC_SWEETS', 'machine', '   ', null, 'pgtap-issue-blank')$$,
  'A comment describing the issue is required', 'a blank comment is rejected'
);

-- 4: a nonexistent job is rejected.
select throws_like(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000099'::uuid, 'ARABIC_SWEETS', 'machine', 'Mixer broken', null, 'pgtap-issue-nojob')$$,
  '%not found%', 'a nonexistent production job is rejected'
);

-- a claimed department that does not match the job's real department is
-- rejected, so a caller cannot corrupt department-scoped escalation/day-end
-- reporting by mislabeling a job.
select throws_like(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'FUSION_SWEETS', 'machine', 'Mixer broken', null, 'pgtap-issue-wrongdept')$$,
  '%does not match production job%', 'a department mismatched against the real job department is rejected'
);

-- 5,6,7: a valid report succeeds, starts open, and appends an escalation event.
select lives_ok(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'ARABIC_SWEETS', 'machine', 'Mixer broken', null, 'pgtap-issue-1')$$,
  'a valid issue report succeeds'
);
select is(
  (select status from public.production_issues where correlation_id = 'pgtap-issue-1'),
  'open', 'a newly reported issue starts open'
);
select is(
  (select count(*) from public.operational_events where correlation_id = 'pgtap-issue-1' and event_type = 'production_issue_escalation'),
  1::bigint, 'reporting an issue appends exactly one production_issue_escalation operational_event'
);

-- 8: retrying the same correlation_id is idempotent -- no duplicate issue or event.
select lives_ok(
  $$select public.report_production_issue('99d50000-0000-0000-0000-000000000001'::uuid, 'ARABIC_SWEETS', 'machine', 'Mixer broken', null, 'pgtap-issue-1')$$,
  'retrying the same correlation_id is idempotent'
);
select is(
  (select count(*) from public.production_issues where correlation_id = 'pgtap-issue-1'),
  1::bigint, 'the idempotent retry created no duplicate production_issues row'
);
select is(
  (select count(*) from public.operational_events where correlation_id = 'pgtap-issue-1' and event_type = 'production_issue_escalation'),
  1::bigint, 'the idempotent retry appended no duplicate production_issue_escalation event'
);

-- 9: resolving as a non-staff role is rejected.
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.resolve_production_issue((select id from public.production_issues where correlation_id = 'pgtap-issue-1'), 'Mixer repaired')$$,
  'Not authorised to resolve a production issue', 'a non-staff role cannot resolve a production issue'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';

-- 10: blank resolution notes are rejected.
select throws_ok(
  $$select public.resolve_production_issue((select id from public.production_issues where correlation_id = 'pgtap-issue-1'), '   ')$$,
  'Resolution notes are required', 'blank resolution notes are rejected'
);

-- 11,12,13: a valid resolve succeeds, records resolver/timestamp, and appends a resolution event.
select lives_ok(
  $$select public.resolve_production_issue((select id from public.production_issues where correlation_id = 'pgtap-issue-1'), 'Mixer repaired by maintenance')$$,
  'a valid resolve succeeds'
);
select is(
  (select status from public.production_issues where correlation_id = 'pgtap-issue-1'),
  'resolved', 'the issue is now resolved'
);
select is(
  (select resolved_by from public.production_issues where correlation_id = 'pgtap-issue-1'),
  '99d00000-0000-0000-0000-000000000001'::uuid, 'the resolver is recorded'
);
select isnt(
  (select resolved_at from public.production_issues where correlation_id = 'pgtap-issue-1'),
  null, 'the resolution timestamp is recorded'
);

-- 14: resolving an already-resolved issue is a safe no-op, not an error.
select lives_ok(
  $$select public.resolve_production_issue((select id from public.production_issues where correlation_id = 'pgtap-issue-1'), 'Mixer repaired by maintenance')$$,
  'resolving an already-resolved issue is idempotent'
);
select is(
  (select count(*) from public.operational_events where entity_id = (select id from public.production_issues where correlation_id = 'pgtap-issue-1') and event_type = 'production_issue_resolved'),
  1::bigint, 'the idempotent re-resolve did not append a duplicate resolution event'
);

-- 15,16,17: direct client mutation of production_issues fails even for an
-- internal-staff caller who would otherwise pass the RLS policy -- the
-- REVOKE, not just the RPC's own application-level check, is what closes
-- the write-only-sink/bypass gap. set local role actually switches the
-- enforced Postgres privileges for this transaction, on top of the
-- request.jwt.claim.* GUCs already used elsewhere in this file (which only
-- drive auth.uid()/RLS predicates, not GRANT/REVOKE checks).
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select throws_ok(
  $$insert into public.production_issues (department, issue_type, comment) values ('ARABIC_SWEETS', 'machine', 'direct insert attempt')$$,
  'permission denied for table production_issues',
  'a direct client INSERT is rejected even for an internal-staff role (bypassing report_production_issue)'
);
select throws_ok(
  $$update public.production_issues set status = 'resolved' where correlation_id = 'pgtap-issue-1'$$,
  'permission denied for table production_issues',
  'a direct client UPDATE is rejected even for an internal-staff role (bypassing resolve_production_issue)'
);
select throws_ok(
  $$delete from public.production_issues where correlation_id = 'pgtap-issue-1'$$,
  'permission denied for table production_issues',
  'a direct client DELETE is rejected even for an internal-staff role'
);

reset role;

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
