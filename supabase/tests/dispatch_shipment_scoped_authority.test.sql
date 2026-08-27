begin;
-- Contract coverage for 20260822131000_dispatch_shipment_scoped_authority.sql.
-- Proves the owner's simplified, single-flat-capability Dispatch model:
-- DISPATCH_INCHARGE/MANAGER/HEAD all get IDENTICAL access (no tiers);
-- confidentiality is enforced by what the view/RPCs structurally return and
-- permit, never by role proliferation.
select plan(55);

select has_function('public', 'can_manage_b2b_dispatch', 'the pre-existing flat Dispatch predicate is unchanged (8: no regression)');
select has_view('public', 'b2b_dispatch_command_queue', 'the pre-existing dispatch command queue view still exists (8: no regression)');
select has_view('public', 'b2b_dispatch_so_line_fulfilment', 'the pre-existing SO-line fulfilment view still exists (8: no regression)');
select has_view('public', 'b2b_dispatch_shipment_execution_view', 'the new shipment-scoped execution view exists');
select has_function('public', 'override_dispatch_priority', 'override_dispatch_priority exists');
select has_function('public', 'raise_dispatch_shipping_data_exception', 'raise_dispatch_shipping_data_exception exists');
select has_function('public', 'correct_dispatch_shipping_snapshot', 'correct_dispatch_shipping_snapshot exists');

insert into public.users (id, role) values
  ('99000000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99000000-0000-0000-0000-000000000002', 'DISPATCH_MANAGER'),
  ('99000000-0000-0000-0000-000000000003', 'DISPATCH_HEAD'),
  ('99000000-0000-0000-0000-000000000004', 'SALES_EXECUTIVE'),
  ('99000000-0000-0000-0000-000000000005', 'FINANCE_HEAD'),
  ('99000000-0000-0000-0000-000000000006', 'admin');

-- Flat capability, no tiers: all three existing role literals pass the SAME
-- predicate identically -- there is no separate "operator" vs "manager"
-- check anywhere in this migration.
select ok(public.can_manage_b2b_dispatch('99000000-0000-0000-0000-000000000001'), 'DISPATCH_INCHARGE has the (single, flat) dispatch capability');
select ok(public.can_manage_b2b_dispatch('99000000-0000-0000-0000-000000000002'), 'DISPATCH_MANAGER has the SAME capability, not an elevated tier');
select ok(public.can_manage_b2b_dispatch('99000000-0000-0000-0000-000000000003'), 'DISPATCH_HEAD has the SAME capability, not an elevated tier');
select ok(NOT public.can_manage_b2b_dispatch('99000000-0000-0000-0000-000000000004'), 'a non-dispatch staff role (sales) does not have dispatch capability');

-- =================================================================================
-- Fixtures: a fully-wired B2B order/consignment carrying a commercial
-- footprint (salesperson, credit, discount, sales value) that must never
-- surface through the new view, plus a second, unreleased consignment to
-- prove the safe-default HOLD collapse.
-- =================================================================================
insert into public.companies (id, business_name, account_manager_id, credit_limit, discount_percentage, total_outstanding, price_tier, phone)
values ('99100000-0000-0000-0000-000000000001', 'Dispatch Test Buyer Co', '99000000-0000-0000-0000-000000000004', 500000, 12.5, 75000, 'A', '+91-9000000000');

insert into public.crm_tasks (id, company_id, sales_exec_id, due_date, description)
values ('99200000-0000-0000-0000-000000000001', '99100000-0000-0000-0000-000000000001', '99000000-0000-0000-0000-000000000004', current_date, 'Follow up on repeat order opportunity');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, payment_status, advance_paid, advance_required, order_origin)
values ('99300000-0000-0000-0000-000000000001', 'PGTAP-DISPATCH-ORD-1', 'pgtap-dispatch-fixture-token-1', '99100000-0000-0000-0000-000000000001', 250000, 'partial', 50000, 250000, 'SALES');

insert into public.products (id, name, category, sku, hsn_code, production_department)
values ('99400000-0000-0000-0000-000000000001', 'Dispatch Test Tray', 'sweets', 'DISPATCH-TRAY-1', '1905', null);

insert into public.order_items (id, order_id, product_id, quantity)
values ('99500000-0000-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001', '99400000-0000-0000-0000-000000000001', 20);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, committed_cutoff, destination_snapshot, handling_instructions, correlation_id
) values (
  '99600000-0000-0000-0000-000000000001', 'PGTAP-CONS-1', '99300000-0000-0000-0000-000000000001', 1, 'ready_to_load', 'road_transporter',
  '2026-09-01T10:00:00Z',
  jsonb_build_object(
    'consignee_name', 'Dispatch Test Buyer Co',
    'address_line1', '221B Industrial Estate',
    'city', 'Chennai', 'state', 'Tamil Nadu', 'pincode', '600001',
    'delivery_contact_name', 'Warehouse Manager', 'delivery_contact_phone', '+91-9111111111'
  ),
  jsonb_build_object('delivery_instructions', 'Call before arrival; use the rear dock'),
  'pgtap-cons-1'
);

insert into public.b2b_dispatch_consignment_lines (
  id, consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty, accepted_ready_qty, packed_qty, dispatched_qty
) values (
  '99700000-0000-0000-0000-000000000001', '99600000-0000-0000-0000-000000000001', '99500000-0000-0000-0000-000000000001',
  '99400000-0000-0000-0000-000000000001', 'DISPATCH-TRAY-1', 'box', 20, 20, 20, 20, 0
);

insert into public.b2b_dispatch_cartons (id, carton_code, consignment_id, carton_sequence)
values ('99800000-0000-0000-0000-000000000001', 'PGTAP-CARTON-1', '99600000-0000-0000-0000-000000000001', 1);

insert into public.b2b_dispatch_shipments (id, consignment_id, shipment_number, transporter_name, vehicle_number, tracking_lr_awb, correlation_id)
values ('99900000-0000-0000-0000-000000000001', '99600000-0000-0000-0000-000000000001', 'PGTAP-SHIP-1', 'Test Transport Co', 'TN-01-AB-1234', 'LR-99001', 'pgtap-ship-1');

insert into public.b2b_dispatch_packing_list_versions (id, consignment_id, version_number, correlation_id)
values ('99a00000-0000-0000-0000-000000000001', '99600000-0000-0000-0000-000000000001', 1, 'pgtap-dpl-1');

insert into public.b2b_dispatch_releases (
  id, consignment_id, packing_list_version_id, release_state, invoice_reference, pi_reference,
  released_by, released_at, finance_evidence_ref, correlation_id
) values (
  '99b00000-0000-0000-0000-000000000001', '99600000-0000-0000-0000-000000000001', '99a00000-0000-0000-0000-000000000001',
  'commercially_clear', 'INV-PGTAP-1', 'PI-PGTAP-1',
  '99000000-0000-0000-0000-000000000005', now(), 'finance-evidence-pgtap-1', 'pgtap-release-1'
);

update public.orders set eway_bill_number = 'EWAY-PGTAP-1', eway_bill_url = 'https://example.test/eway/pgtap-1'
where id = '99300000-0000-0000-0000-000000000001';

-- A second, not-yet-released consignment on a fresh order -- must collapse to HOLD.
insert into public.orders (id, order_number, tracking_token, company_id, order_origin)
values ('99300000-0000-0000-0000-000000000002', 'PGTAP-DISPATCH-ORD-2', 'pgtap-dispatch-fixture-token-2', '99100000-0000-0000-0000-000000000001', 'SALES');
insert into public.b2b_dispatch_consignments (id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id)
values ('99600000-0000-0000-0000-000000000002', 'PGTAP-CONS-2', '99300000-0000-0000-0000-000000000002', 1, 'draft', 'road_transporter', 'pgtap-cons-2');

-- =================================================================================
-- 1 & 2: Dispatch can access everything needed to execute the shipment and
-- print a label -- consignee, ship-to address, delivery contact, products/
-- cartons, transporter, invoice/e-way-bill, for an eligible shipment.
-- (Label rendering/printing itself is a Central-side concern; this proves
-- the governed data source for it is complete and correctly scoped.)
--
-- set local role actually switches the enforced Postgres role for the rest
-- of this transaction (unlike the request.jwt.claim.* GUCs alone), so the
-- view's security_invoker=true and the underlying tables' RLS actually
-- apply here -- without it, this whole file runs as the owning superuser,
-- which bypasses RLS entirely and would only prove the view's join logic,
-- not that a genuine Dispatch role can read it.
-- =================================================================================
set local request.jwt.claim.sub = '99000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select consignee_name from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'Dispatch Test Buyer Co', 'consignee name is available for the specific shipment (1,2)'
);
select is(
  (select ship_to_address_line1 from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  '221B Industrial Estate', 'approved ship-to address is available (1,2)'
);
select is(
  (select delivery_contact_name from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'Warehouse Manager', 'delivery contact is available (1,2)'
);
select is(
  (select carton_count from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  1::bigint, 'carton count is available (1)'
);
select is(
  (select transporter_name from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'Test Transport Co', 'transporter is available (1)'
);
select is(
  (select invoice_reference from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'INV-PGTAP-1', 'invoice reference is available (1)'
);
select is(
  (select eway_bill_number from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'EWAY-PGTAP-1', 'e-way bill reference is available (1)'
);

-- =================================================================================
-- 3 & 4: structurally cannot expose salesperson ownership or CRM history --
-- the view has no such columns at all, regardless of who queries it.
--
-- reset role for the information_schema.view_column_usage checks below:
-- that catalog view filters rows by the querying role's privileges on the
-- underlying table, so running it as 'authenticated' (SELECT-only on
-- governed tables) can silently hide real dependencies and make a
-- structural zero-count assertion vacuously true. The dependency-structure
-- assertion is not an RLS behavioural check, so it must run with full
-- catalog visibility, not the RLS-scoped role.
-- =================================================================================
reset role;
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'account_manager_id', 'no salesperson/account-manager column (3)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'sales_exec_id', 'no sales-exec column (3)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'crm_notes', 'no CRM notes column (4)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'crm_task_description', 'no CRM task column (4)');
select is(
  (select count(*)::int from information_schema.view_column_usage
   where view_schema = 'public' and view_name = 'b2b_dispatch_shipment_execution_view'
     and table_name in ('companies', 'crm_tasks')),
  0, 'the view never reads from companies or crm_tasks at all (3,4 -- structural, not a column filter)'
);
select ok(
  (select count(*) from information_schema.view_column_usage
   where view_schema = 'public' and view_name = 'b2b_dispatch_shipment_execution_view'
     and table_name = 'b2b_dispatch_consignments') > 0,
  'the catalog query can see the view''s real dependencies at all (positive control for 3,4 -- a zero count above is not vacuous)'
);
set local request.jwt.claim.sub = '99000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

-- =================================================================================
-- 5: financial details are never exposed beyond CLEARED/HOLD (plus the
-- legally-required invoice/e-way-bill references already proven above).
-- =================================================================================
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'sales_order_value', 'no raw commercial order value (5)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'payment_status', 'no raw payment status (5)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'advance_paid', 'no raw advance-paid figure (5)');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'release_state', 'no raw uncollapsed release_state (5)');
select is(
  (select finance_status from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  'CLEARED', 'a commercially-released consignment collapses to CLEARED (5)'
);
select is(
  (select finance_status from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000002'),
  'HOLD', 'a consignment with no release decision defaults safely to HOLD, never CLEARED (5)'
);

-- =================================================================================
-- 6: Dispatch cannot edit approved shipping identity directly.
-- =================================================================================
select throws_ok(
  $$ update public.b2b_dispatch_consignments
       set destination_snapshot = jsonb_build_object('consignee_name', 'Rewritten By Dispatch')
       where id = '99600000-0000-0000-0000-000000000001' $$,
  'destination_snapshot is approved shipping identity and cannot be edited directly -- raise a correction via raise_dispatch_shipping_data_exception(), which an admin resolves via correct_dispatch_shipping_snapshot()',
  'a dispatch-authorised role cannot directly rewrite destination_snapshot (6)'
);
select lives_ok(
  $$ select public.raise_dispatch_shipping_data_exception(
       '99600000-0000-0000-0000-000000000001', 'Pincode looks wrong for this city', 'pgtap-shipex-1'
     ) $$,
  'Dispatch can raise a shipping-data correction exception instead (6)'
);
select is(
  (select exception_type from public.b2b_dispatch_exceptions where correlation_id = 'pgtap-shipex-1'),
  'shipping_data_correction_required', 'the exception is recorded with the correct type, not a direct edit (6)'
);

-- =================================================================================
-- 7: Dispatch cannot arbitrarily manipulate priority.
-- =================================================================================
select throws_ok(
  $$ update public.b2b_dispatch_consignments
       set committed_cutoff = '2020-01-01T00:00:00Z'
       where id = '99600000-0000-0000-0000-000000000001' $$,
  'committed_cutoff can only be changed via override_dispatch_priority()',
  'a dispatch-authorised role cannot directly rewrite committed_cutoff (7)'
);
select throws_ok(
  $$ select public.override_dispatch_priority(
       '99600000-0000-0000-0000-000000000001', '2026-09-02T10:00:00Z', '   ', 'pgtap-override-blank'
     ) $$,
  'A reason is required to override dispatch priority',
  'a blank reason is refused (7)'
);
select lives_ok(
  $$ select public.override_dispatch_priority(
       '99600000-0000-0000-0000-000000000001', '2026-09-02T10:00:00Z', 'Customer escalation approved by ops', 'pgtap-override-1'
     ) $$,
  'a governed override with a reason succeeds (7)'
);
select is(
  (select committed_cutoff from public.b2b_dispatch_consignments where id = '99600000-0000-0000-0000-000000000001'),
  '2026-09-02T10:00:00Z'::timestamptz, 'the override actually changes the system priority ordering (7)'
);
select is(
  (select reason from public.b2b_dispatch_priority_overrides where correlation_id = 'pgtap-override-1'),
  'Customer escalation approved by ops', 'the override reason is recorded in the audit trail (7)'
);
select is(
  (select previous_committed_cutoff from public.b2b_dispatch_priority_overrides where correlation_id = 'pgtap-override-1'),
  '2026-09-01T10:00:00Z'::timestamptz, 'the audit trail records the OLD value, not just the new one (7)'
);
select is(
  (select actor_id from public.b2b_dispatch_priority_overrides where correlation_id = 'pgtap-override-1'),
  '99000000-0000-0000-0000-000000000001'::uuid, 'the override is actor-attributed (7)'
);
select throws_like(
  $$ select public.override_dispatch_priority(
       '99600000-0000-0000-0000-000000000002', '2026-09-04T10:00:00Z', 'reusing another shipment''s correlation id', 'pgtap-override-1'
     ) $$,
  '%already in use by a different consignment%',
  'reusing an override correlation_id against a different consignment is rejected, not silently no-op''d (7)'
);
select throws_like(
  $$ select public.raise_dispatch_shipping_data_exception(
       '99600000-0000-0000-0000-000000000002', 'pincode looks wrong for this route', 'pgtap-shipex-1'
     ) $$,
  '%already in use by a different consignment%',
  'reusing an exception correlation_id against a different consignment is rejected, not silently no-op''d (7)'
);

set local request.jwt.claim.sub = '99000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select public.override_dispatch_priority(
       '99600000-0000-0000-0000-000000000001', '2026-09-03T10:00:00Z', 'sales wants this faster', 'pgtap-override-sales'
     ) $$,
  'Not authorised to override dispatch priority',
  'a non-dispatch role (sales) cannot override priority either (7)'
);

-- =================================================================================
-- 8: destination_snapshot must not be permanently uncorrectable once Dispatch
-- has raised a correction exception -- an admin (never a can_manage_b2b_dispatch
-- role) is the only one who can act on it, and doing so resolves the exception.
-- =================================================================================
set local request.jwt.claim.sub = '99000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000001',
       jsonb_build_object('consignee_name', 'Corrected By Dispatch Itself'),
       'trying to self-approve', 'pgtap-shipfix-unauthorised'
     ) $$,
  'Not authorised to correct approved shipping data',
  'a dispatch-authorised (but non-admin) role cannot correct shipping data itself (8)'
);

set local request.jwt.claim.sub = '99000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000001',
       jsonb_build_object('consignee_name', 'Corrected Pincode Co'),
       '   ', 'pgtap-shipfix-blank-reason'
     ) $$,
  'A reason is required to correct shipping data',
  'a blank correction reason is refused (8)'
);
select lives_ok(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000001',
       jsonb_build_object(
         'consignee_name', 'Dispatch Test Buyer Co', 'address_line1', '221B Industrial Estate',
         'city', 'Chennai', 'state', 'Tamil Nadu', 'pincode', '600002',
         'delivery_contact_name', 'Warehouse Manager', 'delivery_contact_phone', '+91-9111111111'
       ),
       'Pincode corrected per raised exception', 'pgtap-shipfix-1',
       (select id from public.b2b_dispatch_exceptions where correlation_id = 'pgtap-shipex-1')
     ) $$,
  'an admin can correct the shipping snapshot and resolve the originating exception in one call (8)'
);
select is(
  (select destination_pincode from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  '600002', 'the corrected pincode is actually reflected in the shipment view (8)'
);
select is(
  (select status from public.b2b_dispatch_exceptions where correlation_id = 'pgtap-shipex-1'),
  'resolved', 'the originating exception is auto-resolved by the correction that addressed it (8)'
);
select is(
  (select previous_destination_snapshot ->> 'pincode' from public.b2b_dispatch_shipping_corrections where correlation_id = 'pgtap-shipfix-1'),
  '600001', 'the correction audit row records the OLD snapshot value, not just the new one (8)'
);
select lives_ok(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000001',
       jsonb_build_object('consignee_name', 'A retry payload that must not apply'),
       'retry', 'pgtap-shipfix-1'
     ) $$,
  'retrying the same correction correlation_id is idempotent (8)'
);
select is(
  (select count(*)::int from public.b2b_dispatch_shipping_corrections where correlation_id = 'pgtap-shipfix-1'),
  1, 'the idempotent retry creates no second correction row (8)'
);
select is(
  (select destination_pincode from public.b2b_dispatch_shipment_execution_view where consignment_id = '99600000-0000-0000-0000-000000000001'),
  '600002', 'the idempotent retry does not re-apply a different payload (8)'
);
select throws_like(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000002',
       jsonb_build_object('consignee_name', 'Reusing another shipment''s correlation id'),
       'cross-consignment reuse attempt', 'pgtap-shipfix-1'
     ) $$,
  '%already in use by a different consignment%',
  'reusing a correction correlation_id against a different consignment is rejected (8)'
);
-- CodeRabbit-flagged bug: p_exception_id must belong to the consignment being
-- corrected. Without this check, a mismatched exception_id would be stored
-- unchecked on the audit row, and the resolution UPDATE (correctly scoped to
-- consignment_id) would silently touch zero rows while the call still
-- reported success -- leaving the real exception open with no error raised.
select throws_like(
  $$ select public.correct_dispatch_shipping_snapshot(
       '99600000-0000-0000-0000-000000000002',
       jsonb_build_object('consignee_name', 'Correcting the wrong shipment''s exception'),
       'mismatched exception id', 'pgtap-shipfix-badexception',
       (select id from public.b2b_dispatch_exceptions where correlation_id = 'pgtap-shipex-1')
     ) $$,
  '%does not belong to consignment%',
  'an exception_id belonging to a different consignment is rejected, not silently ignored (8)'
);
select is(
  (select count(*)::int from public.b2b_dispatch_shipping_corrections where correlation_id = 'pgtap-shipfix-badexception'),
  0, 'the rejected mismatched-exception call creates no audit row (8)'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
