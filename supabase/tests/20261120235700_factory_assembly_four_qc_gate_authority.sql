-- Contract for migration 20261120235700_factory_assembly_four_qc_gate_authority.sql
-- F28: four separately recorded QC decisions, independent final review,
-- blocked transitions after commissioning. The feature defaults OFF until
-- protected owner-policy / floor UAT evidence exists.
BEGIN;
SELECT plan(68);
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
SELECT is(
  has_table_privilege('service_role','public.assembly_qc_gate_events_v1','INSERT'), false,
  'service-role caller cannot directly insert fabricated QC evidence'
);
SELECT is(
  has_table_privilege('service_role','public.assembly_qc_gate_events_v1','UPDATE'), false,
  'service-role caller cannot mutate QC audit history'
);
SELECT is(
  has_table_privilege('service_role','public.assembly_qc_gate_events_v1','DELETE'), false,
  'service-role caller cannot delete QC audit history'
);
SELECT is(
  has_table_privilege('service_role','public.assembly_qc_gate_events_v1','TRUNCATE'), false,
  'service-role caller cannot truncate QC audit history'
);
SELECT has_function('public','assembly_qc_reservation_signature_v1',
  'input QC reservation signature helper exists');
SELECT is(
  (SELECT count(*)::integer FROM pg_trigger
   WHERE tgname='trg_assembly_qc_positive_consumption' AND tgenabled='O'), 1,
  'positive assembly consumption is guarded by a commissioned trigger'
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
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-b'),
 -- A historical/corrupt pending QC job without a known completion actor.
 ('5f280000-0000-0000-0000-000000000043','FACT-F28-JOB-NO-COMPLETER',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'qc_pending','fact-f28-job-no-completer'),
 ('5f280000-0000-0000-0000-000000000044','FACT-F28-JOB-C',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-c'),
 ('5f280000-0000-0000-0000-000000000045','FACT-F28-JOB-D',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'in_progress','fact-f28-job-d'),
 ('5f280000-0000-0000-0000-000000000046','FACT-F28-JOB-E',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'qc_pending','fact-f28-job-e'),
 ('5f280000-0000-0000-0000-000000000047','FACT-F28-JOB-MISSING-FINAL',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'qc_pending','fact-f28-job-missing-final'),
 ('5f280000-0000-0000-0000-000000000048','FACT-F28-JOB-MISSING-INPUT',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-missing-input'),
 ('5f280000-0000-0000-0000-000000000049','FACT-F28-JOB-ISSUE-AFTER-INPUT',
  '5f280000-0000-0000-0000-000000000021','5f280000-0000-0000-0000-000000000031',
  'FACT-F28-OUT',10,'materials_reserved','fact-f28-job-issue-after-input');
INSERT INTO public.b2b_assembly_components(
 id,assembly_job_id,product_id,sku,source_store_code,required_qty,reserved_qty,issued_qty
) VALUES
 ('5f280000-0000-0000-0000-000000000051','5f280000-0000-0000-0000-000000000042',
 '5f280000-0000-0000-0000-000000000031','FACT-F28-OUT','FINISHED_GOODS',1,0,0),
 ('5f280000-0000-0000-0000-000000000052','5f280000-0000-0000-0000-000000000044',
 '5f280000-0000-0000-0000-000000000031','FACT-F28-OUT','FINISHED_GOODS',1,1,1),
 ('5f280000-0000-0000-0000-000000000053','5f280000-0000-0000-0000-000000000045',
 '5f280000-0000-0000-0000-000000000031','FACT-F28-OUT','FINISHED_GOODS',1,1,1),
 ('5f280000-0000-0000-0000-000000000054','5f280000-0000-0000-0000-000000000046',
 '5f280000-0000-0000-0000-000000000031','FACT-F28-OUT','FINISHED_GOODS',1,1,1),
 ('5f280000-0000-0000-0000-000000000055','5f280000-0000-0000-0000-000000000049',
 '5f280000-0000-0000-0000-000000000031','FACT-F28-OUT','FINISHED_GOODS',1,1,0);

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
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000042',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:stale-input','checked','f28-input-stale')
$qc$,'input QC is recorded before a later reservation change');

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
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FINAL','FAIL',2,'evidence:f28:final-fail','self-rejected','f28-final-self-fail')
$qc$,'%ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER%',
 'the assembly completer cannot self-reject final QC with FAIL');
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FINAL','HOLD',2,'evidence:f28:final-hold','self-held','f28-final-self-hold')
$qc$,'%ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER%',
 'the assembly completer cannot self-place final QC on HOLD');

SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000012';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000041',
  'FINAL','PASS',2,'evidence:f28:final',NULL,'f28-final-other')
$qc$,'a different authorized reviewer can approve final QC');

-- Even with three historical PASS events, a missing completion actor
-- cannot establish an independent final reviewer. This is a rollback-only
-- consistency fixture, not a supported application path to create jobs.
INSERT INTO public.assembly_qc_gate_events_v1(
 assembly_job_id,gate,decision,sample_qty,evidence_reference,inspected_by,correlation_id,reservation_signature
) VALUES
 ('5f280000-0000-0000-0000-000000000043','INPUT_MATERIAL','PASS',1,
  'evidence:f28:legacy-input','5f280000-0000-0000-0000-000000000011','f28-legacy-input',
  public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000043')),
 ('5f280000-0000-0000-0000-000000000043','FIRST_PIECE','PASS',1,
  'evidence:f28:legacy-first','5f280000-0000-0000-0000-000000000011','f28-legacy-first',NULL),
 ('5f280000-0000-0000-0000-000000000043','IN_PROCESS','PASS',1,
  'evidence:f28:legacy-process','5f280000-0000-0000-0000-000000000011','f28-legacy-process',NULL);
SELECT throws_like($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000043',
  'FINAL','PASS',1,'evidence:f28:legacy-final',NULL,'f28-legacy-final')
$qc$,'%ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER%',
 'missing completion actor fails closed rather than permitting unverifiable final QA');

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
UPDATE public.b2b_assembly_components
 SET reserved_qty=reserved_qty+1
 WHERE id='5f280000-0000-0000-0000-000000000051';
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='issued'
  WHERE id='5f280000-0000-0000-0000-000000000042'
$qc$,'%ASSEMBLY_INPUT_QC_RESERVATION_CHANGED%',
 'commissioned material issue rejects input QC for a changed reservation');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000042'),
 'materials_reserved','changed reservation preserves original assembly status');

SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='issued'
  WHERE id='5f280000-0000-0000-0000-000000000048'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'commissioned material issue is blocked without input QC evidence');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000048'),
 'materials_reserved','missing input gate preserves original assembly status');

INSERT INTO public.assembly_qc_gate_events_v1(
 assembly_job_id,gate,decision,sample_qty,evidence_reference,inspected_by,correlation_id,reservation_signature
) VALUES
 ('5f280000-0000-0000-0000-000000000047','INPUT_MATERIAL','PASS',1,
 'evidence:f28:missing-final-input','5f280000-0000-0000-0000-000000000011','f28-missing-final-input',
 public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000047')),
 ('5f280000-0000-0000-0000-000000000047','FIRST_PIECE','PASS',1,
 'evidence:f28:missing-final-first','5f280000-0000-0000-0000-000000000011','f28-missing-final-first',NULL),
 ('5f280000-0000-0000-0000-000000000047','IN_PROCESS','PASS',1,
 'evidence:f28:missing-final-process','5f280000-0000-0000-0000-000000000011','f28-missing-final-process',NULL);
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='accepted'
  WHERE id='5f280000-0000-0000-0000-000000000047'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'commissioned acceptance is blocked when final QC is missing');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000047'),
 'qc_pending','missing final gate preserves original assembly status');

SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000011';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000044',
  'INPUT_MATERIAL','PASS',1,'evidence:f28:c-input','checked','f28-c-input')
$qc$,'failed-gate fixture records input QC');
UPDATE public.b2b_assembly_jobs SET status='issued'
WHERE id='5f280000-0000-0000-0000-000000000044';
UPDATE public.b2b_assembly_jobs SET status='in_progress'
WHERE id='5f280000-0000-0000-0000-000000000044';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
  '5f280000-0000-0000-0000-000000000044',
  'FIRST_PIECE','FAIL',1,'evidence:f28:c-first','stop process','f28-c-first-fail')
$qc$,'failed-gate fixture records a first-piece FAIL');
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='qc_pending'
  WHERE id='5f280000-0000-0000-0000-000000000044'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'commissioned completion is blocked by a failed first-piece gate');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000044'),
 'in_progress','failed intermediate gate preserves original assembly status');

INSERT INTO public.assembly_qc_gate_events_v1(
 assembly_job_id,gate,decision,sample_qty,evidence_reference,inspected_by,correlation_id,reservation_signature
) VALUES
 ('5f280000-0000-0000-0000-000000000045','INPUT_MATERIAL','PASS',1,
 'evidence:f28:d-input','5f280000-0000-0000-0000-000000000011','f28-d-input',
 public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000045')),
 ('5f280000-0000-0000-0000-000000000045','FIRST_PIECE','PASS',1,
 'evidence:f28:d-first','5f280000-0000-0000-0000-000000000011','f28-d-first',NULL),
 ('5f280000-0000-0000-0000-000000000045','IN_PROCESS','PASS',1,
 'evidence:f28:d-process','5f280000-0000-0000-0000-000000000011','f28-d-process',NULL),
 ('5f280000-0000-0000-0000-000000000045','FIRST_PIECE','PASS',1,
 'evidence:f28:d-first-new','5f280000-0000-0000-0000-000000000011','f28-d-first-new',NULL);
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='qc_pending'
  WHERE id='5f280000-0000-0000-0000-000000000045'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'a newer first-piece event invalidates the older in-process approval');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000045'),
 'in_progress','downstream supersession preserves original assembly status');

INSERT INTO public.assembly_qc_gate_events_v1(
 assembly_job_id,gate,decision,sample_qty,evidence_reference,reason,inspected_by,correlation_id,reservation_signature
) VALUES
 ('5f280000-0000-0000-0000-000000000046','INPUT_MATERIAL','PASS',1,
 'evidence:f28:e-input',NULL,'5f280000-0000-0000-0000-000000000011','f28-e-input',
 public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000046')),
 ('5f280000-0000-0000-0000-000000000046','FIRST_PIECE','PASS',1,
 'evidence:f28:e-first',NULL,'5f280000-0000-0000-0000-000000000011','f28-e-first',NULL),
 ('5f280000-0000-0000-0000-000000000046','IN_PROCESS','PASS',1,
 'evidence:f28:e-process',NULL,'5f280000-0000-0000-0000-000000000011','f28-e-process',NULL),
 ('5f280000-0000-0000-0000-000000000046','FINAL','FAIL',1,
 'evidence:f28:e-final','reject product','5f280000-0000-0000-0000-000000000012','f28-e-final',NULL);
SELECT throws_like($qc$
 UPDATE public.b2b_assembly_jobs SET status='accepted'
  WHERE id='5f280000-0000-0000-0000-000000000046'
$qc$,'%ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED%',
 'commissioned acceptance is blocked by a failed final inspection');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000046'),
 'qc_pending','failed final gate preserves original assembly status');
SELECT lives_ok($qc$
 UPDATE public.b2b_assembly_jobs SET status='rejected'
  WHERE id='5f280000-0000-0000-0000-000000000046'
$qc$,'a recorded failed final inspection permits governed rejection');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
 WHERE id='5f280000-0000-0000-0000-000000000046'),
 'rejected','failed final evidence leaves a rejected assembly status');

SELECT throws_like($qc$
 UPDATE public.b2b_assembly_components SET consumed_qty=1
  WHERE id='5f280000-0000-0000-0000-000000000052'
$qc$,'%ASSEMBLY_QC_CONSUMPTION_BLOCKED%',
 'commissioned positive consumption is blocked after failed first-piece QC');
SELECT is(
 (SELECT consumed_qty FROM public.b2b_assembly_components
 WHERE id='5f280000-0000-0000-0000-000000000052'),
 0::numeric,'blocked consumption leaves the component quantity unchanged');


-- Real issue ordering: INPUT_MATERIAL inspection is recorded BEFORE
-- issued_qty is increased. Issuing the inspected stock must not invalidate
-- that PASS; only a reservation amendment must invalidate it.
SET LOCAL request.jwt.claim.sub='5f280000-0000-0000-0000-000000000011';
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
 '5f280000-0000-0000-0000-000000000049',
 'INPUT_MATERIAL','PASS',1,'evidence:f28:preissue',NULL,'f28-preissue-pass')
$qc$,'input QC accepts the reserved component while issued quantity remains zero');
SELECT is(
 (SELECT issued_qty FROM public.b2b_assembly_components
  WHERE id='5f280000-0000-0000-0000-000000000055'),
 0::numeric,'input material approval precedes the physical issue step');
UPDATE public.b2b_assembly_components SET issued_qty=1
 WHERE id='5f280000-0000-0000-0000-000000000055';
SELECT is(
 (SELECT reservation_signature FROM public.assembly_qc_gate_events_v1
  WHERE correlation_id='f28-preissue-pass'),
 public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000049'),
 'physical issue increments issued_qty without invalidating reserved input QC');
SELECT lives_ok($qc$
 UPDATE public.b2b_assembly_jobs SET status='issued'
  WHERE id='5f280000-0000-0000-0000-000000000049'
$qc$,'commissioned issue transition succeeds with unchanged reservation');
SELECT is(
 (SELECT status FROM public.b2b_assembly_jobs
  WHERE id='5f280000-0000-0000-0000-000000000049'),
 'issued','normal issued job status is not blocked by the inspection signature');
SELECT lives_ok($qc$
 UPDATE public.b2b_assembly_jobs SET status='in_progress'
 WHERE id='5f280000-0000-0000-0000-000000000049'
$qc$,'issued job can progress to active work after preserved input material QC');
SELECT lives_ok($qc$
 SELECT public.record_assembly_qc_gate_v1(
 '5f280000-0000-0000-0000-000000000049',
 'FIRST_PIECE','PASS',1,'evidence:f28:postissue-first',NULL,'f28-postissue-first')
$qc$,'FIRST_PIECE QC succeeds after normal material issue without stale approval failure');

SELECT ok(
 position('issued_qty' IN pg_get_functiondef(
   'public.assembly_qc_reservation_signature_v1(uuid)'::regprocedure))=0,
 'reservation fingerprint does not depend on normal material issued_qty changes');
SELECT ok(
 position('assembly_component_lot_issues' IN pg_get_functiondef(
   'public.assembly_qc_reservation_signature_v1(uuid)'::regprocedure))=0,
 'reservation fingerprint does not depend on issue-generated lot lineage rows');
UPDATE public.b2b_assembly_components
 SET returned_qty=1 WHERE id='5f280000-0000-0000-0000-000000000055';
SELECT is(
 (SELECT reservation_signature FROM public.assembly_qc_gate_events_v1
  WHERE correlation_id='f28-preissue-pass'),
 public.assembly_qc_reservation_signature_v1('5f280000-0000-0000-0000-000000000049'),
 'return quantity changes do not invalidate earlier reserved-material inspection');


SELECT * FROM finish();
ROLLBACK;
