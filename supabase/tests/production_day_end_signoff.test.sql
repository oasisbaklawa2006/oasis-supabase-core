begin;
-- Contract coverage for 20260822170000_production_day_end_signoff.sql.
select plan(22);

select has_function('public', 'submit_production_day_end', 'submit_production_day_end exists');
select has_table('public', 'production_day_end_signoffs', 'production_day_end_signoffs exists');
select has_view('public', 'production_day_end_current', 'production_day_end_current view exists');

insert into public.users (id, role) values
  ('99e00000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('99e00000-0000-0000-0000-000000000002', 'HOD_FUSION'),
  ('99e00000-0000-0000-0000-000000000003', 'B2B_BUYER');

insert into public.orders (id, order_number, tracking_token, order_origin)
values ('99e30000-0000-0000-0000-000000000001', 'PGTAP-DAYEND-ORD-1', 'pgtap-dayend-token-1', 'MANUAL');

insert into public.products (id, name, category, sku, hsn_code, production_department)
values ('99e40000-0000-0000-0000-000000000001', 'Day-End Test Tray', 'sweets', 'DAYEND-TRAY-1', '1905', 'arabic_sweets');

-- Job 1: still in production (WIP, carries forward unmodified).
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, produced_qty, status, priority)
values ('99e50000-0000-0000-0000-000000000001', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 'arabic_sweets', 20, 5, 'in_production', 'urgent');

insert into public.production_job_outputs (job_id, produced_qty, wasted_qty, batch_number, correlation_id)
values ('99e50000-0000-0000-0000-000000000001', 5, 1, 'BATCH-DAYEND-1', 'pgtap-dayend-output-1');

-- Job 2: paused.
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('99e50000-0000-0000-0000-000000000002', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 'arabic_sweets', 10, 'paused');
insert into public.production_pauses (job_id, reason, comment)
values ('99e50000-0000-0000-0000-000000000002', 'machine_breakdown', 'Mixer down');

-- Job 3: an open production issue against the same department.
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('99e50000-0000-0000-0000-000000000003', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 'arabic_sweets', 5, 'in_production');

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000001';
select public.report_production_issue('99e50000-0000-0000-0000-000000000003'::uuid, 'arabic_sweets', 'machine', 'Oven overheating', null, 'pgtap-dayend-issue-1');

-- 1: unauthorised (non-staff) caller is rejected.
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000003';
select throws_ok(
  $$select public.submit_production_day_end('arabic_sweets', current_date, null, null, 'pgtap-dayend-noauth')$$,
  'Not authorised to submit a production day-end signoff', 'a non-staff role cannot submit a day-end signoff'
);

-- 2: a HOD cannot sign off a different department's day.
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.submit_production_day_end('arabic_sweets', current_date, null, null, 'pgtap-dayend-wrongdept')$$,
  'Actor is not authorised to sign off department ARABIC_SWEETS', 'a HOD cannot sign off a different department''s day-end'
);

set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000001';

-- 3: an unknown department is rejected.
select throws_like(
  $$select public.submit_production_day_end('not_a_real_department', current_date, null, null, 'pgtap-dayend-baddept')$$,
  '%Unknown production department%', 'an unmapped department string is rejected'
);

-- 4: a future business date is rejected.
select throws_ok(
  $$select public.submit_production_day_end('arabic_sweets', current_date + 1, null, null, 'pgtap-dayend-future')$$,
  'Cannot sign off a future business date', 'a future business date is rejected'
);

-- 5,6,7,8: a valid signoff succeeds and the summary reflects real state --
-- never a fabricated or zeroed-out number.
select lives_ok(
  $$select public.submit_production_day_end('arabic_sweets', current_date, 'Mixer down since morning, awaiting spare part', null, 'pgtap-dayend-1')$$,
  'a valid HOD day-end signoff succeeds for their own department'
);
select is(
  (select department from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1'),
  'ARABIC_SWEETS', 'the department is recorded in its canonical form'
);
select is(
  ((select summary from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1') ->> 'quantity_produced_today')::numeric,
  5::numeric, 'the summary reflects the real recorded output, not a fabricated number'
);
select is(
  jsonb_array_length((select summary from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1') -> 'paused_jobs'),
  1, 'the summary lists the one real paused job'
);
select is(
  jsonb_array_length((select summary from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1') -> 'escalations_open'),
  1, 'the summary lists the one real open escalation'
);

-- 9: production_jobs is never mutated by signing off the day -- job 1
-- must still be exactly where it was (rolls forward unmodified).
select is(
  (select status from public.production_jobs where id = '99e50000-0000-0000-0000-000000000001'),
  'in_production', 'day-end signoff never mutates an open production job''s status'
);

-- 10: retrying the same correlation_id is idempotent.
select lives_ok(
  $$select public.submit_production_day_end('arabic_sweets', current_date, 'Mixer down since morning, awaiting spare part', null, 'pgtap-dayend-1')$$,
  'retrying the same correlation_id is idempotent'
);
select is(
  (select count(*) from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1'),
  1::bigint, 'the idempotent retry created no duplicate signoff'
);

-- 11,12: the signoff is append-only -- direct UPDATE/DELETE are rejected.
select throws_ok(
  $$update public.production_day_end_signoffs set exception_notes = 'edited' where correlation_id = 'pgtap-dayend-1'$$,
  'production_day_end_signoffs is append-only -- submit a correcting signoff instead',
  'a direct UPDATE to a signed-off record is rejected'
);
select throws_ok(
  $$delete from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1'$$,
  'production_day_end_signoffs is append-only -- submit a correcting signoff instead',
  'a direct DELETE of a signed-off record is rejected'
);

-- 13,14: a correction is a NEW row referencing the original, never an edit,
-- and production_day_end_current resolves to the latest one.
select lives_ok(
  $$select public.submit_production_day_end(
      'arabic_sweets', current_date, 'Correction: spare part arrived, mixer back online by EOD',
      (select id from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-1'), 'pgtap-dayend-1-correction'
    )$$,
  'a correcting signoff referencing the original succeeds'
);
select is(
  (select count(*) from public.production_day_end_signoffs where department = 'ARABIC_SWEETS' and business_date = current_date),
  2::bigint, 'the correction is a second row, not an edit of the first'
);
select is(
  (select correlation_id from public.production_day_end_current where department = 'ARABIC_SWEETS' and business_date = current_date),
  'pgtap-dayend-1-correction', 'production_day_end_current resolves to the latest (corrected) signoff'
);

-- 15: a correction must reference a signoff for the same department/date.
insert into public.production_day_end_signoffs (department, business_date, summary, signed_by, correlation_id)
values ('FUSION_SWEETS', current_date, '{}'::jsonb, '99e00000-0000-0000-0000-000000000002', 'pgtap-dayend-fusion-1');
select throws_ok(
  $$select public.submit_production_day_end(
      'arabic_sweets', current_date, null,
      (select id from public.production_day_end_signoffs where correlation_id = 'pgtap-dayend-fusion-1'), 'pgtap-dayend-mismatch'
    )$$,
  'A correction must reference a signoff for the same department and business date',
  'a correction referencing a different department''s signoff is rejected'
);

-- 16: reusing a correlation_id for a genuinely different department/date is
-- rejected, not silently returned as if it were the same signoff. The actor
-- must actually be authorised for FUSION_SWEETS so this exercises the
-- cross-entity correlation_id check, not the (already-covered) department
-- authority check.
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000002';
select throws_like(
  $$select public.submit_production_day_end('fusion_sweets', current_date, null, null, 'pgtap-dayend-1')$$,
  '%already in use by a different department or business date%',
  'reusing a correlation_id for a different department is rejected'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
