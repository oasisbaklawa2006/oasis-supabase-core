begin;
-- Contract coverage for 20260819120000_pna_assembly_job_governed_authority.sql:
-- governed assembly job lifecycle RPCs on b2b_assembly_jobs/b2b_assembly_components,
-- including the fail-closed partial-reservation/issue gate, governed 3PGS
-- requirements, post-handover reconciliation, and receiver-acknowledged
-- custody transfer added after semantic review against the P&A specification.
select plan(85);

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
select has_function('public', 'compute_assembly_job_variance', 'compute_assembly_job_variance exists');
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

-- STORE_INCHARGE (not HOD_ASSEMBLY) so the dispatcher fixture also holds
-- receive authority: the self-acknowledgement test below must exercise the
-- distinct-actor gate specifically, not merely fail on receive-role authority.
insert into public.users (id, role) values
  ('17000000-0000-0000-0000-000000000001', 'STORE_INCHARGE'),
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

-- ASM-JOB-1 carries only a FINISHED_GOODS (RGS/Production) shortfall -- a
-- real, implemented lane a manager may legitimately authorise proceeding
-- ahead of. Its packaging/3PGS counterpart is deliberately a SEPARATE job
-- (ASM-JOB-3PGS-BOUNDARY, below): mixing the two in one fixture would let a
-- resolvable food shortfall's success mask whether the unresolvable 3PGS
-- boundary is actually enforced. See that job for the 3PGS proof.
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-1', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 20,
       jsonb_build_array(
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000002', 'sku', 'KUNAFA-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 10)
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
  1, 'the food component was snapshotted (Level 0 input)'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
       'normal', 'corr-asm-reserve-1'
     ) $$,
  'reserve_assembly_components succeeds'
);

-- Fix 1: the job must NOT reach materials_reserved while a component remains
-- short.
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

-- =================================================================================
-- ASM-JOB-3PGS-BOUNDARY: the 3PGS dependency-boundary proof.
--
-- 3PGS (the 3rd Party/Contract Store) is an EXISTING, partially-built
-- operational module in Central (ThirdPartyStore, ThirdPartyExecutionBoard,
-- thirdPartyQueueFeed, departmental routing) -- it is NOT unbuilt. What is
-- new here is b2b_assembly_3pgs_requirements itself (this same migration):
-- no existing 3PGS surface consumes this specific governed requirement type
-- yet, so there is no vendor order, picking, collection or stock-crediting
-- workflow wired to fulfil_assembly_3pgs_requirement today. That wiring is
-- 3PGS COMPLETION WORK PENDING in the dedicated 3PGS build lane, not a
-- claim that 3PGS itself does not exist. This job's ONLY component is a
-- 3PGS-sourced packaging shortfall, proving:
--   (a) reserve_assembly_components still raises a real, governed, exactly
--       job/component-linked b2b_assembly_3pgs_requirements row and never
--       fabricates a production shortage job for it;
--   (b) authorize_partial_assembly_issue -- P&A's own manager-authority
--       override -- refuses, unconditionally, to bypass an unresolved
--       3PGS/packaging/outsourced shortfall (unlike a FINISHED_GOODS
--       shortfall, which IS authorisable -- see ASM-JOB-1 above -- because
--       RGS/Production is a real, implemented lane);
--   (c) issue_assembly_components therefore never proceeds, so the job can
--       never falsely become materially ready, issued, or Job Completed;
--   (d) even exercising fulfil_assembly_3pgs_requirement -- the real,
--       already-implemented governed interface the existing 3PGS module
--       will call once extended -- does not itself credit any stock or
--       unblock the job, since no such crediting mechanism is wired yet.
--       The boundary holds before AND after that interface is exercised,
--       not just before.
-- This is a dependency-boundary proof, not a claim that P&A<->3PGS full
-- operational fulfilment already works end-to-end -- that remains DEFERRED
-- until the existing 3PGS module is extended to consume this contract.
-- =================================================================================
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-3PGS-BOUNDARY', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 5,
       jsonb_build_array(
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000003', 'sku', 'RIBBON-COMP-1', 'source_store_code', '3PGS', 'required_qty', 15)
       ),
       'corr-asm-3pgsb-create-1'
     ) $$,
  'create_assembly_job opens a job whose only component is a 3PGS-sourced, currently-unfulfillable packaging shortfall'
);
select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'),
       'normal', 'corr-asm-3pgsb-reserve-1'
     ) $$,
  'reserve_assembly_components succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'),
  'partially_reserved', 'the 3PGS boundary job cannot reach materials_reserved while its only component is an unfulfilled 3PGS shortfall'
);
select is(
  (select count(*)::int from public.production_jobs pj
     join public.b2b_assembly_components c on c.product_id = pj.product_id
     where c.assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY')),
  0, 'a packaging/3PGS shortfall never creates a production shortage job'
);
select is(
  (select count(*)::int from public.b2b_assembly_3pgs_requirements r
     join public.b2b_assembly_components c on c.id = r.assembly_component_id
     where c.assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY')
       and r.status = 'open' and r.requested_qty = 15),
  1, 'the packaging shortfall raises a governed open 3PGS requirement, exactly linked to this job and component'
);

select throws_like(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'),
       'Attempting to bypass the outstanding ribbon/3PGS shortfall',
       'corr-asm-3pgsb-authorize-blocked'
     ) $$,
  '%3PGS completion work pending%',
  'authorize_partial_assembly_issue refuses, unconditionally, to bypass an unresolved 3PGS/packaging shortfall'
);
select throws_like(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'), 'corr-asm-3pgsb-issue-blocked'
     ) $$,
  '%issue refused without an authorized partial-issue plan%',
  'issue_assembly_components stays blocked -- the job never obtains an authorisation to act on'
);

-- fulfil_assembly_3pgs_requirement is a real, already-implemented governed
-- RPC -- the interface point the existing 3PGS module will call once
-- extended to consume it. Exercising it here is a contract test of that
-- interface, NOT a claim that P&A can self-fulfil its own request: it
-- requires can_receive_b2b_inventory (a different authority than the
-- assembly/dispatcher identity used above), and recording it does not
-- itself credit any stock -- proving the dependency boundary holds even
-- once this interface is exercised.
set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.fulfil_assembly_3pgs_requirement(
       (select r.id from public.b2b_assembly_3pgs_requirements r
          join public.b2b_assembly_components c on c.id = r.assembly_component_id
          where c.assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY')),
       15, 'corr-asm-3pgsb-fulfil-1'
     ) $$,
  'fulfil_assembly_3pgs_requirement is a real, callable governed contract for the existing 3PGS module to consume once extended'
);
select is(
  (select r.status from public.b2b_assembly_3pgs_requirements r
     join public.b2b_assembly_components c on c.id = r.assembly_component_id
     where c.assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY')),
  'fulfilled', 'the requirement record itself is marked fulfilled'
);
set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
select is(
  (select c.reserved_qty from public.b2b_assembly_components c
     where c.assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY')),
  0::numeric, 'marking the requirement fulfilled does not itself credit any stock -- no 3PGS stock-crediting mechanism exists yet'
);
select throws_like(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'),
       'Requirement marked fulfilled -- attempting to proceed',
       'corr-asm-3pgsb-authorize-still-blocked'
     ) $$,
  '%3PGS completion work pending%',
  'the job still cannot be issued once the requirement is merely marked fulfilled -- nothing real actually changed'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-3PGS-BOUNDARY'),
  'partially_reserved', 'the 3PGS boundary job remains stuck at partially_reserved -- it can never falsely reach materially ready or Job Completed today'
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
       'Production dispatch deadline -- proceeding with kunafa short, RGS/Production shortage demand already raised',
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

-- ASM-JOB-1 has no unaccounted component residue and a fully-acknowledged
-- handover, so its true server-computed variance is genuinely zero here
-- (see the ASM-JOB-2 fixture below for the non-zero-variance fail-closed
-- proof -- reconcile_assembly_job no longer accepts a caller-supplied
-- variance figure at all, so it cannot be faked on this job either).
select is(
  public.compute_assembly_job_variance((select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1')),
  0::numeric, 'ASM-JOB-1 has a genuine zero computed variance (no residue, fully-acknowledged handover)'
);
select lives_ok(
  $$ select public.reconcile_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), null, 'corr-asm-reconcile-1'
     ) $$,
  'reconcile_assembly_job succeeds with a genuine zero variance'
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

-- ================================================================================
-- ASM-JOB-2: two remaining fail-closed defects found in a further semantic
-- review of the head commit.
--   (a) acknowledge_assembly_handover's Handed Over gate was aggregating
--       dispatched_qty instead of receiver-acknowledged received_qty -- a
--       short receipt could satisfy handover as long as enough was DECLARED
--       dispatched. Proven below: a 10-of-18 receipt must not move the job,
--       a zero receipt must not either, and only the genuine remaining 8
--       (through a second acknowledgement, real custody evidence) does.
--   (b) reconcile_assembly_job trusted a caller-supplied p_variance_qty.
--       Proven below: leftover unaccounted component residue (issued but
--       never consumed/wasted/returned) produces a genuine non-zero
--       server-computed variance that a caller cannot suppress -- the RPC
--       no longer even accepts a variance parameter, only explanatory notes,
--       and the persisted figure is asserted to be the true computed value.
-- ================================================================================
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('27000000-0000-0000-0000-000000000004', 'Baklawa Tray Output', 'sweets', 'BAKLAWA-OUT-1', '1905', 'arabic_sweets'),
  ('27000000-0000-0000-0000-000000000005', 'Pistachio Filling Component', 'sweets', 'PISTACHIO-COMP-1', '1905', 'arabic_sweets');
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('27000000-0000-0000-0000-000000000005', 'PISTACHIO-COMP-1', 'FINISHED_GOODS', 50);

set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-2', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000004', 'BAKLAWA-OUT-1', 20,
       jsonb_build_array(jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000005', 'sku', 'PISTACHIO-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 10)),
       'corr-asm2-create-1', '2'
     ) $$,
  'create_assembly_job opens ASM-JOB-2 (fully-stocked, no shortfall)'
);
select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'), 'normal', 'corr-asm2-reserve-1'
     ) $$,
  'reserve_assembly_components succeeds with sufficient stock'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  'materials_reserved', 'ASM-JOB-2 reaches materials_reserved directly (no shortfall)'
);
select lives_ok(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'), 'corr-asm2-issue-1'
     ) $$,
  'issue_assembly_components succeeds with no authorization required (fully reserved)'
);

-- Leaves 1 unit of component residue unaccounted for (10 issued, only 9
-- dispositioned as consumed/wasted/returned) -- the real, computable
-- non-zero variance this fixture exists to prove.
select lives_ok(
  $$ select public.record_assembly_consumption(
       (select c.id from public.b2b_assembly_components c
          join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
          where j.assembly_job_number = 'ASM-JOB-2' and c.sku = 'PISTACHIO-COMP-1'),
       8, 1, 0, 'corr-asm2-consume-1'
     ) $$,
  'record_assembly_consumption leaves 1 unit of component residue unaccounted for'
);
select lives_ok(
  $$ select public.complete_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'), 18, 'corr-asm2-complete-1'
     ) $$,
  'complete_assembly_job succeeds for ASM-JOB-2'
);
select lives_ok(
  $$ select public.accept_assembly_output(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'), 18, 0, 'corr-asm2-accept-1'
     ) $$,
  'accept_assembly_output succeeds for ASM-JOB-2'
);

-- (a) Handed Over gate: authoritative receiver-acknowledged quantity, never
-- declared/dispatched quantity.
select lives_ok(
  $$ select public.initiate_assembly_handover(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
       '3PGS', '3PGS-PACKING-STORE', 18, 3, 'trace-evidence-corr-2', 'corr-asm2-handover-init-1'
     ) $$,
  'initiate_assembly_handover dispatches the full accepted quantity for ASM-JOB-2'
);

set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_assembly_handover(
       (select id from public.b2b_assembly_handovers where correlation_id = 'corr-asm2-handover-init-1'),
       10, 'trace-evidence-corr-2-receipt-partial', 'corr-asm2-handover-ack-short'
     ) $$,
  'a short 10-of-18 receipt is recorded'
);
select is(
  (select (handed_over_at is not null)::text || '|' || status
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  'false|accepted', 'a short receipt (10 of 18 dispatched) must NOT satisfy Handed Over'
);
select is(
  (select status from public.b2b_assembly_handovers where correlation_id = 'corr-asm2-handover-init-1'),
  'partially_acknowledged', 'the handover itself reflects partial acknowledgement, not full acknowledgement'
);

select lives_ok(
  $$ select public.acknowledge_assembly_handover(
       (select id from public.b2b_assembly_handovers where correlation_id = 'corr-asm2-handover-init-1'),
       0, 'trace-evidence-corr-2-receipt-zero', 'corr-asm2-handover-ack-zero'
     ) $$,
  'a zero-quantity acknowledgement call is accepted as a no-op custody checkpoint'
);
select is(
  (select (handed_over_at is not null)::text || '|' || status
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  'false|accepted', 'a zero receipt cannot satisfy Handed Over either'
);

select lives_ok(
  $$ select public.acknowledge_assembly_handover(
       (select id from public.b2b_assembly_handovers where correlation_id = 'corr-asm2-handover-init-1'),
       8, 'trace-evidence-corr-2-receipt-remainder', 'corr-asm2-handover-ack-remainder'
     ) $$,
  'the genuine remaining 8 units are subsequently acknowledged through valid custody evidence'
);
select is(
  (select (handed_over_at is not null)::text || '|' || status
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  'true|reconciliation_pending', 'only once the full 18 is receiver-acknowledged does the job become Handed Over'
);
select is(
  (select received_qty from public.b2b_assembly_handovers where correlation_id = 'corr-asm2-handover-init-1'),
  18::numeric, 'received_qty accumulated across the three acknowledgement calls (10 + 0 + 8)'
);

-- (b) Reconciliation must be server-derived, never caller-declared.
select is(
  public.compute_assembly_job_variance((select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2')),
  1::numeric, 'the true computed variance (1 unit of unaccounted component residue) is derived from recorded data'
);
set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
select throws_like(
  $$ select public.reconcile_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'), null, 'corr-asm2-reconcile-blocked'
     ) $$,
  '%variance%requires explanatory notes%',
  'reconcile_assembly_job fails closed on the genuine unexplained non-zero variance -- notes cannot be omitted'
);
select lives_ok(
  $$ select public.reconcile_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
       '1 unit of pistachio filling recorded as neither consumed, wasted nor returned -- written off after floor check',
       'corr-asm2-reconcile-1'
     ) $$,
  'reconcile_assembly_job succeeds once the real variance is explained'
);
select is(
  (select reconciliation_variance_qty from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  1::numeric, 'the PERSISTED variance is the true server-computed figure, proving caller input cannot suppress or override it'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-2'),
  'job_completed', 'ASM-JOB-2 reaches Job Completed once its real variance is reconciled'
);

select finish();
rollback;
