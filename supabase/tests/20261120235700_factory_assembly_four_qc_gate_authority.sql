-- Contract for migration 20261120235700_factory_assembly_four_qc_gate_authority.sql
-- F28: four separately recorded QC decisions, independent final review,
-- blocked transitions after commissioning. The feature defaults OFF until
-- protected owner-policy / floor UAT evidence exists.
BEGIN;
SELECT plan(17);
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
SELECT * FROM finish();
ROLLBACK;
