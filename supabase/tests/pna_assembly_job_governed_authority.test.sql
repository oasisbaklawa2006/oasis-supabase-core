begin;
-- Contract coverage for 20260819120000_pna_assembly_job_governed_authority.sql:
-- governed assembly job lifecycle RPCs on b2b_assembly_jobs/b2b_assembly_components,
-- including the fail-closed partial-reservation/issue gate, governed 3PGS
-- requirements, post-handover reconciliation, and receiver-acknowledged
-- custody transfer added after semantic review against the P&A specification.
select plan(56);

select has_function('public', 'create_assembly_job', 'create_assembly_job exists');
select has_function('public', 'reserve_assembly_components', 'reserve_assembly_components exists');
select has_function('public', 'authorize_partial_assembly_issue', 'authorize_partial_assembly_issue exists');
select has_function('public', 'issue_assembly_components', 'issue_assembly_components exists');
select has_function('public', 'record_assembly_consumption', 'record_assembly_consumption exists');
select has_function('public', 'complete_assembly_job', 'complete_assembly_job exists');
select has_function('public', 'accept_assembly_output', 'accept_assembly_output exists');
select has_function('public', 'create_assembly_3pgs_requirement', 'create_assembly_3pgs_requirement exists');
select has_function('public', 'fulfil_assembly_3pgs_requirement', 'fulfil_assembly_3pgs_requirement exists');
select has_function('public', 'initiate_assembly_handover', 'initiate_assembly_handover exists');
select has_function('public', 'acknowledge_assembly_handover', 'acknowledge_assembly_handover exists');
select has_function('public', 'reconcile_assembly_job', 'reconcile_assembly_job exists');
select has_function('public', 'close_assembly_job', 'close_assembly_job exists');

-- Direct table writes are revoked now that the RPC layer exists.
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_jobs', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_assembly_jobs'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_components', 'UPDATE')),
  false, 'authenticated cannot directly update b2b_assembly_components'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_3pgs_requirements', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_assembly_3pgs_requirements'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_handovers', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_assembly_handovers'
);

insert into public.users (id, role) values
  ('17000000-0000-0000-0000-000000000001', 'HOD_ASSEMBLY'),
  ('17000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('27000000-0000-0000-0000-000000000001', 'Hamper Box Output', 'hampers', 'HAMPER-OUT-1', '1905', null),
  ('27000000-0000-0000-0000-000000000002', 'Kunafa Roll Component', 'sweets', 'KUNAFA-COMP-1', '1905', 'arabic_sweets'),
  ('27000000-0000-0000-0000-000000000003', 'Ribbon Packaging Component', 'packaging', 'RIBBON-COMP-1', '4823', null);
insert into public.orders (id, order_number, tracking_token) values
  ('37000000-0000-0000-0000-000000000001', 'PGTAP-ORD-ASSEMBLY-1', 'pgtap-fixture-token-assembly-1');

-- Food component has only partial stock (shortfall must route to RGS/Production).
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('27000000-0000-0000-0000-000000000002', 'KUNAFA-COMP-1', 'FINISHED_GOODS', 4);
-- Packaging component is fully short (must NOT route to Production; must raise a 3PGS requirement).
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('27000000-0000-0000-0000-000000000003', 'RIBBON-COMP-1', '3PGS', 0);

set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- Level 1B output is hamper-only (fix 6): rejected without job_purpose = 'hamper'.
select throws_like(
  $$ select public.create_assembly_job(
       'ASM-JOB-BAD-1B', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 5,
       jsonb_build_array(jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000002', 'sku', 'KUNAFA-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 1)),
       'corr-asm-bad-1b', '1B', 'retail_pack'
     ) $$,
  '%hamper-only%',
  'Level 1B output without job_purpose=hamper is refused'
);

select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-1', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 20,
       jsonb_build_array(
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000002', 'sku', 'KUNAFA-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 10),
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000003', 'sku', 'RIBBON-COMP-1', 'source_store_code', '3PGS', 'required_qty', 20)
       ),
       'corr-asm-create-1', '1A', 'retail_pack', 'bom-v3', 'master-v7'
     ) $$,
  'create_assembly_job opens a job with its components and Level/purpose/version metadata'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'planned', 'new job starts in planned status'
);
select is(
  (select output_level || '|' || job_purpose || '|' || bom_version || '|' || master_data_version
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  '1A|retail_pack|bom-v3|master-v7', 'Level, purpose, BOM version and master-data version are recorded'
);
select is(
  (select count(*)::int from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1'),
  2, 'both components were snapshotted (Level 0 inputs)'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
       'normal', 'corr-asm-reserve-1'
     ) $$,
  'reserve_assembly_components succeeds'
);

-- Fix 1: the job must NOT reach materials_reserved while a component remains
-- short. Both components are short here (food partially, packaging fully).
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'partially_reserved', 'job reaches partially_reserved, not materials_reserved, while any component is short'
);
select is(
  (select c.reserved_qty from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'KUNAFA-COMP-1'),
  4::numeric, 'food component reserves only the available quantity'
);

-- Food shortfall (10 required, 4 available) must route to RGS then Production
-- via the existing governed RPCs, never a direct P&A -> Production write.
select is(
  (select count(*)::int from public.inventory_reservations
     where demand_source_type = 'pna' and demand_reference = 'ASM-JOB-1'
       and product_id = '27000000-0000-0000-0000-000000000002'),
  1, 'a food shortfall opens an RGS demand-source reservation'
);
select is(
  (select count(*)::int from public.production_jobs pj
     join public.inventory_reservations ir on ir.id = pj.reservation_id
     where ir.demand_source_type = 'pna' and ir.demand_reference = 'ASM-JOB-1'),
  1, 'the unmet food shortfall is routed to a Production shortage job'
);

-- Packaging shortfall (20 required, 0 available at 3PGS) must NOT create any
-- production_jobs row, and MUST raise a governed 3PGS requirement (fix 2)
-- instead of merely sitting under-reserved.
select is(
  (select count(*)::int from public.production_jobs pj
     join public.b2b_assembly_components c on c.product_id = pj.product_id
     where c.sku = 'RIBBON-COMP-1'),
  0, 'a packaging shortfall never creates a production shortage job'
);
select is(
  (select c.reserved_qty from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'RIBBON-COMP-1'),
  0::numeric, 'the packaging component is left under-reserved pending 3PGS fulfilment'
);
select is(
  (select count(*)::int from public.b2b_assembly_3pgs_requirements r
     join public.b2b_assembly_components c on c.id = r.assembly_component_id
     where c.sku = 'RIBBON-COMP-1' and r.status = 'open' and r.requested_qty = 20),
  1, 'the packaging shortfall raises a governed open 3PGS requirement for the full shortfall'
);

-- Fix 1: issue fails closed on an unauthorized incomplete reservation.
select throws_like(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-issue-blocked'
     ) $$,
  '%issue refused without an authorized partial-issue plan%',
  'issue_assembly_components fails closed on an unauthorized partially_reserved job'
);

select throws_like(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), '   ', 'corr-asm-authorize-empty'
     ) $$,
  '%reason is required%',
  'authorize_partial_assembly_issue requires a non-empty reason'
);
select lives_ok(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
       'Production dispatch deadline -- proceeding with kunafa short, ribbon fully 3PGS-outstanding',
       'corr-asm-authorize-1'
     ) $$,
  'authorize_partial_assembly_issue records an explicit reasoned authorisation'
);
select is(
  (select partial_issue_authorized from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  true, 'partial issue is now authorized'
);

select lives_ok(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-issue-1'
     ) $$,
  'issue_assembly_components succeeds once an authorized partial-issue plan exists'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'issued', 'job moves to issued after authorized partial issuance'
);

select lives_ok(
  $$ select public.record_assembly_consumption(
       (select c.id from public.b2b_assembly_components c
          join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
          where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'KUNAFA-COMP-1'),
       4, 0, 0, 'corr-asm-consume-1'
     ) $$,
  'record_assembly_consumption succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'in_progress', 'job moves to in_progress on first consumption'
);

-- Fix 3: complete_assembly_job is packing/execution completion leading to QC
-- only, never the authoritative Job Completed state.
select lives_ok(
  $$ select public.complete_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 18, 'corr-asm-complete-1'
     ) $$,
  'complete_assembly_job succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'qc_pending', 'complete_assembly_job only reaches qc_pending, never Job Completed'
);

select lives_ok(
  $$ select public.accept_assembly_output(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 18, 0, 'corr-asm-accept-1'
     ) $$,
  'accept_assembly_output succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'accepted', 'job is fully accepted (Ready)'
);

-- Accepting output must never itself credit any RGS/3PGS-owned stock balance.
select is(
  (select available_qty from public.inventory_stock_balances where sku = 'KUNAFA-COMP-1' and location_code = 'FINISHED_GOODS'),
  0::numeric, 'accept_assembly_output does not credit the RGS-owned FINISHED_GOODS balance'
);

-- Fix 4: receiver-acknowledged custody handover. Destination is configured,
-- never hard-coded; self-acknowledgement by the dispatcher is refused.
select lives_ok(
  $$ select public.initiate_assembly_handover(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
       'RGS', 'RGS-FINISHED-GOODS-STORE', 18, 2, 'trace-evidence-corr-1', 'corr-asm-handover-init-1'
     ) $$,
  'initiate_assembly_handover records the dispatch side with a configured destination'
);
select is(
  (select handed_over_at from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  null, 'initiating a handover does not itself set Handed Over'
);
select throws_like(
  $$ select public.acknowledge_assembly_handover(
       (select id from public.b2b_assembly_handovers where correlation_id = 'corr-asm-handover-init-1'),
       18, 'trace-evidence-corr-1-receipt', 'corr-asm-handover-self-ack'
     ) $$,
  '%different actor%',
  'the dispatcher cannot self-acknowledge its own handover'
);

set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_assembly_handover(
       (select id from public.b2b_assembly_handovers where correlation_id = 'corr-asm-handover-init-1'),
       18, 'trace-evidence-corr-1-receipt', 'corr-asm-handover-ack-1'
     ) $$,
  'a different, receiving actor can acknowledge the handover'
);
select is(
  (select (handed_over_at is not null)::text || '|' || status
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'true|reconciliation_pending', 'Handed Over is set only once the receiver acknowledges, moving the job to reconciliation_pending'
);

-- Fix 3: close_assembly_job is blocked before Job Completed.
set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
select throws_like(
  $$ select public.close_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-close-blocked'
     ) $$,
  '%cannot be closed before it is Job Completed%',
  'close_assembly_job is blocked before reconciliation and Job Completed'
);

-- Fix 3: a non-zero reconciliation variance without notes fails closed.
select throws_like(
  $$ select public.reconcile_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 1, null, 'corr-asm-reconcile-blocked'
     ) $$,
  '%variance requires explanatory notes%',
  'reconcile_assembly_job fails closed on an unexplained non-zero variance'
);
select lives_ok(
  $$ select public.reconcile_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 0, null, 'corr-asm-reconcile-1'
     ) $$,
  'reconcile_assembly_job succeeds with a zero variance'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'job_completed', 'reconciliation sets the authoritative Job Completed state'
);

select lives_ok(
  $$ select public.close_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-close-1'
     ) $$,
  'close_assembly_job succeeds once Job Completed'
);
select is(
  (select (handed_over_at is not null)::text || '|' || (job_completed_at is not null)::text || '|' || (job_closed_at is not null)::text
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'true|true|true', 'Ready, Handed Over, Job Completed and Job Closed are four distinct, separately timestamped states'
);

-- fulfil_assembly_3pgs_requirement: 3PGS's own receiving role can record
-- fulfilment of the earlier-raised requirement.
set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.fulfil_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_3pgs_requirements where requirement_number like 'ASM-JOB-1:3PGS:%'),
       20, 'corr-asm-3pgs-fulfil-1'
     ) $$,
  'fulfil_assembly_3pgs_requirement records 3PGS fulfilment of the requirement'
);
select is(
  (select status from public.b2b_assembly_3pgs_requirements where requirement_number like 'ASM-JOB-1:3PGS:%'),
  'fulfilled', 'the 3PGS requirement is marked fulfilled once fully actioned'
);

select finish();
rollback;
