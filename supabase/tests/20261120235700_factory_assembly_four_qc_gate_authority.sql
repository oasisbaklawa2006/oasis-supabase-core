-- Contract for migration 20261120235700_factory_assembly_four_qc_gate_authority.sql
-- F28: four separately recorded QC decisions, independent final review,
-- blocked transitions after commissioning. The feature defaults OFF until
-- protected owner-policy / floor UAT evidence exists.
BEGIN;
SELECT plan(32);
SELECT has_table('public','assembly_qc_commissioning_v1',
  'single owner-governed QC commissioning configuration exists');
SELECT has_table('public','assembly_qc_gate_events_v1',
  'separate append-only assembly QC evidence exists');
SELECT has_function('public','record_assembly_qc_gate_v1',
  'authenticated QC evidence recording RPC exists');
SELECT has_function('public','assert_assembly_qc_sequence_v1',
  'QC sequence validation helper exists');
SELECT has_function('public','guard_assembly_four_qc_gates_v1',
  'assembly lifecycle QC guard exists');
SELECT is(
  (SELECT enforced FROM public.assembly_qc_commissioning_v1 WHERE id=true), false,
  'new QC enforcement is initially uncommissioned; existing assembly stays compatible'
);
SELECT is(
  (SELECT count(*)::integer FROM pg_trigger
   WHERE tgname='trg_assembly_four_qc_gates' AND tgenabled='O'), 1,
  'QC enforcement trigger is installed at the existing assembly-job state transition'
);
SELECT is(
  has_function_privilege('anon',
   'public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)','EXECUTE'), false,
  'anonymous actor cannot record QC'
);
SELECT is(
  has_function_privilege('authenticated',
   'public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)','EXECUTE'), true,
  'authenticated QC actor can access server-validated recording RPC'
);
SELECT is(
  has_table_privilege('authenticated','public.assembly_qc_gate_events_v1','INSERT'), false,
  'browser cannot directly insert fabricated QC evidence'
);
SELECT ok(
  pg_get_functiondef('public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)'::regprocedure)
  LIKE '%PACKING_SUPERVISOR%', 'QC approvals are restricted to staff role allowlist'
);
SELECT ok(
  pg_get_functiondef('public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)'::regprocedure)
  LIKE '%ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER%',
  'final QC cannot self-approve the completed job'
);
SELECT ok(
  pg_get_functiondef('public.assert_assembly_qc_sequence_v1(uuid,text)'::regprocedure)
  LIKE '%INPUT_MATERIAL%FIRST_PIECE%IN_PROCESS%FINAL%',
  'all four gates are required in fixed order'
);
SELECT ok(
  pg_get_functiondef('public.guard_assembly_four_qc_gates_v1()'::regprocedure)
  LIKE '%NEW.status=%issued%INPUT_MATERIAL%',
  'input material QC is required before material issue when commissioned'
);
SELECT ok(
  pg_get_functiondef('public.guard_assembly_four_qc_gates_v1()'::regprocedure)
  LIKE '%NEW.status=%qc_pending%IN_PROCESS%',
  'first-piece and in-process checks are required before completion'
);
SELECT ok(
  pg_get_functiondef('public.guard_assembly_four_qc_gates_v1()'::regprocedure)
  LIKE '%NEW.status IN (%accepted%FINAL%',
  'final QC is mandatory before accepted assembly stock is recognized'
);
SELECT ok(
  pg_get_functiondef('public.guard_assembly_four_qc_gates_v1()'::regprocedure)
  LIKE '%ASSEMBLY_FINAL_QC_REJECTION_EVIDENCE_REQUIRED%',
  'rejection cannot silently bypass final QA evidence'
);

-- Behavioral regression: independent actors on the existing Assembly job,
-- irreversible QC evidence, and fail-closed enforcement. All seeds roll back.
INSERT INTO public.users(id,role,is_active) VALUES
 ('5f280000-0000-0000-0000-000000000011','HOD_ASSEMBLY',true),
 ('5f280000-0000-0000-0000-000000000012','PACKING_SUPERVISOR',true),
 ('5f280000-0000-0000-0000-000000000013','SALES_EXECUTIVE',true);
INSERT INTO public.products(id,name,category,sku,hsn_code,production_department)
VALUES ('5f280000-0000-0000-0000-000000000031','Factory F28 QC output',
        'hampers','FACT-F28-OUT','1905',NULL);
INSERT INTO public.orders(id,order_number,tracking_token,order_origin)
VALUES ('5f280000-0000-0000-0000-000000000021',
        'FACT-F28-SO','fact-f28-token','MANUAL');
INSERT INTO public.b2b_assembly_jobs(
 id,assembly_job_number,order_id,output_product_id,output_sku,
 planned_qty,status,correlation_id
) VALUES
 ('5f280000-0000-0000-0000-000000000041','FACT-F28-JOB-A',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-a'),
 ('5f280000-0000-0000-0000-000000000042','FACT-F28-JOB-B',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-b');

SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000013';
SET LOCAL request.jwt.claim.role='authenticated';
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:input','checked','f28-input-1')
$qc$,'%ASSEMBLY_QC_REVIEWER_NOT_AUTHORIZED%',
 'non-QC sales role is forbidden to record an Assembly QC event');

SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000011';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:input','checked','f28-input-1')
$qc$,'HOD can record valid input material QC');
SELECT is(
 (SELECT count(*)::integer FROM public.assembly_qc_gate_events_v1
  WHERE assembly_job_id='5f280000-0000-0000-0000-000000000041'),1,
 'input material QC creates exactly one audit event');
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:input','checked','f28-input-1')
$qc$,'exact correlation replay does not duplicate QC evidence');
SELECT is(
 (SELECT count(*)::integer FROM public.assembly_qc_gate_events_v1
  WHERE assembly_job_id='5f280000-0000-0000-0000-000000000041'),1,
 'exact replay retains a single append-only QC event');
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:input','changed','f28-input-1')
$qc$,'%ASSEMBLY_QC_IDEMPOTENCY_PAYLOAD_CONFLICT%',
 'replay with altered QC reason is rejected instead of silently accepted');
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'INPUT_MATERIAL','PASS',0,'evidence:f28:input','checked','f28-input-2')
$qc$,'%ASSEMBLY_QC_EVIDENCE_INVALID%',
 'zero-size QC sample is invalid');

UPDATE public.b2b_assembly_jobs SET status='issued'
 WHERE id='5f280000-0000-0000-0000-000000000041';
UPDATE public.b2b_assembly_jobs SET status='in_progress'
 WHERE id='5f280000-0000-0000-0000-000000000041';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FIRST_PIECE','PASS',1,'evidence:f28:first',NULL,'f28-first-1')
$qc$,'first-piece QC succeeds after passed input QC');
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'IN_PROCESS','PASS',2,'evidence:f28:process',NULL,'f28-process-1')
$qc$,'in-process QC succeeds after first-piece QC');

UPDATE public.b2b_assembly_jobs
 SET status='qc_pending', completed_by='5f280000-0000-0000-0000-000000000011'
 WHERE id='5f280000-0000-0000-0000-000000000041';
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FINAL','PASS',2,'evidence:f28:final',NULL,'f28-final-self')
$qc$,'%ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER%',
 'the assembly completer cannot self-approve final QC');

SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000012';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FINAL','PASS',2,'evidence:f28:final',NULL,'f28-final-other')
$qc$,'a different authorized reviewer can approve final QC');

-- Enable locally only inside rollback-bound pgTAP. Production remains OFF.
UPDATE public.assembly_qc_commissioning_v1
 SET enforced=true,policy_version='PGTAP-F28',changed_at=now() WHERE id=true;
SELECT lives_ok($qc$
 UPDATE public.b2b_assembly_jobs SET status='accepted'
  WHERE id='5f280000-0000-0000-0000-000000000041'
$qc$,'commissioned acceptance permits a fully documented four-gate chain');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
  WHERE id='5f280000-0000-0000-0000-000000000041'),
 'accepted','accepted assembly status is reached only after the four gates');
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='issued'
  WHERE id='5f280000-0000-0000-0000-000000000042'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'commissioned material issue is blocked without input QC evidence');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
  WHERE id='5f280000-0000-0000-0000-000000000042'),
 'materials_reserved','failed gate preserves original assembly status');

SELECT * FROM finish();
ROLLBACK;
