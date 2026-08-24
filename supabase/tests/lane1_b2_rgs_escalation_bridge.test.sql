begin;
-- Contract coverage for 20260824140000_lane1_b2_rgs_escalation_bridge.sql.
select plan(11);

select has_function('public', 'emit_rgs_handover_escalations', 'emit_rgs_handover_escalations exists');

insert into public.users (id, role) values
  ('99e00000-0000-0000-0000-000000000001', 'RGS_ADMIN'),
  ('99e00000-0000-0000-0000-000000000002', 'B2B_BUYER');

insert into public.orders (id, order_number, tracking_token)
values ('99e30000-0000-0000-0000-000000000001', 'PGTAP-B2ESC-ORD-1', 'pgtap-b2esc-token-1');

insert into public.products (id, name, category, sku, hsn_code)
values ('99e40000-0000-0000-0000-000000000001', 'B2 Escalation Test Tray', 'sweets', 'B2ESC-TRAY-1', '1905');

insert into public.production_jobs (id, order_id, product_id, department, canonical_department, priority, assigned_qty)
values ('99e50000-0000-0000-0000-000000000001', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 'ARABIC_SWEETS', 'urgent', 10);

insert into public.production_rgs_transfers (id, job_id, quantity, status)
values ('99e60000-0000-0000-0000-000000000001', '99e50000-0000-0000-0000-000000000001', 5, 'in_transit');

set local request.jwt.claim.role = 'authenticated';

-- 1: unauthenticated caller is rejected.
reset request.jwt.claim.sub;
select throws_ok(
  $$select public.emit_rgs_handover_escalations()$$,
  'Not authorised', 'an unauthenticated caller cannot emit RGS escalation events'
);

-- 2: a non-staff role is rejected.
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.emit_rgs_handover_escalations()$$,
  'Not authorised', 'a non-staff role cannot emit RGS escalation events'
);

set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000001';

-- 3: the unacknowledged handover is emitted exactly once.
select is(
  (select public.emit_rgs_handover_escalations()), 1,
  'one unacknowledged handover produces exactly one emitted event'
);

select is(
  (select count(*)::int from public.operational_events where event_type = 'rgs_handover_escalation'),
  1, 'exactly one rgs_handover_escalation operational_event row exists'
);

select is(
  (select actor_department from public.operational_events where event_type = 'rgs_handover_escalation'),
  'RGS', 'the emitted event is attributed to the RGS department'
);

select is(
  (select severity from public.operational_events where event_type = 'rgs_handover_escalation'),
  'urgent', 'an urgent-priority job''s unacknowledged handover is emitted at urgent severity'
);

-- 4: a repeat call for the same (transfer, status) is idempotent -- no duplicate row.
select lives_ok(
  $$select public.emit_rgs_handover_escalations()$$,
  'a repeat call does not error'
);

select is(
  (select count(*)::int from public.operational_events where event_type = 'rgs_handover_escalation'),
  1, 'a repeat call for the same unacknowledged handover does not insert a second event'
);

-- 5: once the handover reaches a terminal state, it is no longer emitted.
update public.production_rgs_transfers set status = 'accepted' where id = '99e60000-0000-0000-0000-000000000001';

select is(
  (select public.emit_rgs_handover_escalations()), 0,
  'an accepted handover is no longer surfaced as an open escalation'
);

select is(
  (select count(*)::int from public.operational_events where event_type = 'rgs_handover_escalation'),
  1, 'accepting the handover does not retroactively remove or duplicate its earlier escalation event'
);

select * from finish();
rollback;
