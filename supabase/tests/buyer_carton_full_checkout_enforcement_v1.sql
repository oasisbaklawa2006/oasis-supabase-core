-- Contract for 20261113130100_buyer_carton_full_checkout_enforcement_v1.sql
begin;
select plan(67);

set local session_replication_role = replica;
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000d'), ('00000000-0000-0000-0000-0000000000ad');
insert into public.companies (id, business_name, status, is_frozen, discount_percentage) values ('00000000-0000-0000-0000-0000000000a1', 'Co A', 'active', false, 0);
insert into public.profiles (id, company_id, is_approved, status, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', true, 'approved', 'b2b_buyer'),
  ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000000a1', true, 'approved', 'ADMIN');
insert into public.users (id, role, is_active) values ('00000000-0000-0000-0000-00000000000d', 'ADMIN', true);
insert into public.products (id, name, product_name, category, sku, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, uom)
  select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, 'P' || n, 'P' || n, 'bulk_sweets', 'S' || n, '1704', true, true, true, 'tray' from generate_series(1001, 1007) n;
insert into public.product_pricing_rules (product_id, base_price, currency, uom, gst_rate, tax_inclusive, price_channel, approval_status)
  select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, 100, 'INR', case when n = 1003 then 'kg' else 'tray' end, 5, true, 'b2b', 'approved' from generate_series(1001, 1007) n;
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, eligible_packing_groups, mixable_group_sets, approval_status, approved_by, approved_at, evidence_ref) values
  ('c4', 1, 'C4', 'bulk_sweets', 4, 'tray', '{g1,g2}', '[["g1","g2"]]'::jsonb, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV'),
  ('cdraft', 1, 'CD', 'bulk_sweets', 4, 'tray', '{g1}', '[]'::jsonb, 'draft', null, null, null);
-- 1001,1002 slot_unit mixable; 1003 fixed ratio 6 kg per container; 1004 separate carton; 1005 no profile; 1006 unit mismatch; 1007 only a draft carton
insert into public.product_packing_profiles (product_id, packing_group, conversion_basis, slots_per_unit, ordered_units_per_slot, commercial_uom, carton_config_ids, requires_separate_carton, mix_allowed, profile_version, approval_status, approved_by, approved_at, evidence_ref)
  select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, case when n = 1002 then 'g2' else 'g1' end, case when n = 1003 then 'fixed_ratio' else 'slot_unit' end,
         case when n = 1003 then null else 1 end, case when n = 1003 then 6 end, case when n = 1006 then 'kg' when n = 1003 then 'kg' else 'tray' end,
         case when n = 1007 then '{cdraft}'::text[] else '{c4}'::text[] end, n = 1004, n <> 1004, 1, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV'
    from generate_series(1001, 1007) n where n <> 1005;
create or replace function public._t_order(p_lines jsonb, p_exception boolean default false, p_fire boolean default true) returns uuid language plpgsql as $f$
declare o uuid := gen_random_uuid(); l jsonb;
begin
  set local session_replication_role = replica;
  insert into public.orders (id, company_id, status, order_number, order_origin) values (o, '00000000-0000-0000-0000-0000000000a1', 'submitted', 'T-' || o, 'CUSTOMER_APP');
  if p_fire then set local session_replication_role = origin; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    insert into public.order_items (order_id, product_id, quantity, pack_size) values (o, ('00000000-0000-0000-0000-00000000' || (l ->> 'p'))::uuid, (l ->> 'q')::numeric,
      case when l ->> 'p' = '1003' then 'kg' else 'tray' end);
  end loop;
  if not p_fire then set local session_replication_role = origin; return o; end if;
  if p_exception then insert into public.carton_enforcement_exceptions (scope, ref_id, reason, granted_by) values ('order', o, 'test exception for audit coverage', '00000000-0000-0000-0000-00000000000d'); end if;
  set constraints trg_order_items_carton_enforcement immediate;
  set constraints trg_order_items_carton_enforcement deferred;
  return o;
end $f$;
create or replace function public._t_eval(p_lines jsonb) returns jsonb language plpgsql as $f$
declare o uuid := public._t_order(p_lines, false, false); r jsonb;
begin r := public.evaluate_order_carton_completeness_v1(o); return r; end $f$;
create or replace function public._t_gate(p_lines jsonb, p_to text, p_exception boolean default false, p_legacy boolean default false) returns void language plpgsql as $f$
declare o uuid := public._t_order(p_lines, false, false);
begin
  if p_legacy then set local session_replication_role = replica; update public.orders set created_at = now() - interval '1 day' where id = o; set local session_replication_role = origin; end if;
  if p_exception then insert into public.carton_enforcement_exceptions (scope, ref_id, reason, granted_by) values ('order', o, 'dispatch gate exception for audit test', '00000000-0000-0000-0000-00000000000d'); end if;
  update public.orders set status = p_to where id = o;
end $f$;
set local session_replication_role = origin;

-- access control
set local role anon;
select throws_ok($$select public.grant_carton_enforcement_exception_v1('order', gen_random_uuid(), 'anonymous attempt to grant')$$, '42501', NULL, 'anon cannot execute the exception grant');
reset role;
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select throws_ok($$select * from public.carton_enforcement_settings$$, '42501', NULL, 'buyers cannot read the enforcement settings');
select throws_ok($$update public.carton_enforcement_settings set enabled = false$$, '42501', NULL, 'buyers cannot change the enforcement flag');
select throws_ok($$select * from public.carton_enforcement_exceptions$$, '42501', NULL, 'buyers cannot read exceptions');
select throws_ok($$select * from public.carton_enforcement_verifications$$, '42501', NULL,
  'buyers cannot read trusted accepted-carton verification snapshots');
select throws_ok($$select public.grant_carton_enforcement_exception_v1('order', gen_random_uuid(), 'buyer attempting self exception')$$, '42501', NULL, 'buyers cannot grant themselves an exception');
select throws_ok($$select public.evaluate_order_carton_completeness_v1(gen_random_uuid())$$, '42501', NULL, 'the evaluator is not callable by API roles');
reset role;

select ok((select relrowsecurity and relforcerowsecurity from pg_class
  where oid = 'public.carton_enforcement_verifications'::regclass),
  'accepted carton verification evidence is protected with forced RLS');
select ok((select tgdeferrable and tginitdeferred from pg_trigger
  where tgrelid = 'public.orders'::regclass and tgname = 'trg_orders_carton_new_order_enforcement'),
  'empty new orders must be checked at transaction commit');
-- default OFF
select is((select enabled from public.carton_enforcement_settings), false, 'enforcement is disabled by default');
select lives_ok($$select public._t_order('[{"p":"1001","q":1}]')$$, 'flag off: an incomplete carton is not enforced (existing behaviour unchanged)');
update public.carton_enforcement_settings set enabled = true;
select isnt((select enforced_from from public.carton_enforcement_settings), null, 'switching enforcement on records enforced_from');
select ok((select position('order_id' in pg_get_triggerdef(t.oid)) > 0 from pg_trigger t where t.tgrelid = 'public.order_items'::regclass and t.tgname = 'trg_order_items_carton_enforcement'),
  'deferred carton constraint is registered for order_id reassignment, not just product and quantity changes');

-- Both tables acquire the same enabled-mode transaction lock at statement
-- entry, before their row mutations can acquire locks in opposite order.
select ok(exists(
  select 1 from pg_trigger g
  where g.tgrelid = 'public.order_items'::regclass
    and g.tgname = 'trg_carton_line_global_stmt_lock'
    and not g.tgisinternal and g.tgtype & 1 = 0 and g.tgtype & 2 = 2
), 'order line mutations acquire the global lock before row locks');
select ok(exists(
  select 1 from pg_trigger g
  where g.tgrelid = 'public.orders'::regclass
    and g.tgname = 'trg_carton_order_global_stmt_lock'
    and not g.tgisinternal and g.tgtype & 1 = 0 and g.tgtype & 2 = 2
), 'order mutations acquire the global lock before row locks');

-- Post-enforcement order insert timestamps are stamped by the server, not client-provided.
create or replace function public._t_backdated_order_insert() returns boolean language plpgsql as $f$
declare v_order uuid; v_created timestamptz;
begin
  insert into public.orders (company_id, status, order_origin, created_at)
  values ('00000000-0000-0000-0000-0000000000a1', 'submitted', 'CUSTOMER_APP', now() - interval '1 day')
  returning id, created_at into v_order, v_created;
  return v_created >= now() - interval '1 minute';
end $f$;
select ok(public._t_backdated_order_insert(), 'an inserted order cannot supply a pre-cutover created_at after enforcement starts');

select is((public._t_eval('[]') -> 0 ->> 'code'), 'CARTON_ORDER_EMPTY',
  'an empty submitted order is never complete when enforcement is enabled');
-- enforcement ON
select throws_ok($$select public._t_order('[{"p":"1001","q":1}]')$$, '23514', 'CARTON_ENFORCEMENT_VIOLATION', '1 of 4 slots is rejected');
select lives_ok($$select public._t_order('[{"p":"1001","q":4}]')$$, 'a complete carton (4 of 4) is accepted');
select lives_ok($$select public._t_order('[{"p":"1001","q":8}]')$$, 'two complete cartons (8 of 4) are accepted');
create temp table _t_verification_order as select public._t_order('[{"p":"1001","q":2},{"p":"1002","q":2}]') as id;
select is((select z.line_revision from public.carton_enforcement_verifications z
  where z.order_id = (select id from _t_verification_order)),
  (select o.carton_line_revision from public.orders o where o.id = (select id from _t_verification_order)),
  'multi-line orders have exactly one current trusted validation revision');
select lives_ok($$select public._t_order('[{"p":"1001","q":2},{"p":"1002","q":2}]')$$, 'two eligible packing groups may share one full carton only through the approved mixable_group_sets');
select throws_ok($$select public._t_order('[{"p":"1001","q":2},{"p":"1002","q":1}]')$$, '23514', NULL, 'mixed SKUs totalling 3 of 4 slots are rejected');
select lives_ok($$select public._t_order('[{"p":"1003","q":24}]')$$, 'fixed ratio: 24 kg = 4 primary containers = one full carton');
select throws_ok($$select public._t_order('[{"p":"1003","q":18}]')$$, '23514', NULL, 'fixed ratio: 18 kg = 3 containers leaves an incomplete carton');
select is((public._t_eval('[{"p":"1003","q":7}]') -> 0 ->> 'code'), 'PRIMARY_CONTAINER_PARTIAL', '7 kg is a partial primary container (6 kg per container)');
select is((public._t_eval('[{"p":"1005","q":4}]') -> 0 ->> 'code'), 'CARTON_PROFILE_MISSING', 'a SKU without an approved profile fails closed');
select is((public._t_eval('[{"p":"1006","q":4}]') -> 0 ->> 'code'), 'CARTON_UNIT_MISMATCH', 'a profile whose unit differs from the approved price unit fails closed');
select is((public._t_eval('[{"p":"1007","q":4}]') -> 0 ->> 'code'), 'CARTON_CONFIG_NOT_LIVE', 'a profile pointing only at a draft carton fails closed');
select is(jsonb_array_length(public._t_eval('[{"p":"1004","q":2},{"p":"1001","q":2}]')), 2, 'a SKU that needs its own carton is not mixed with another SKU');
-- An approved configuration can contain a NULL in its eligible array with no mix sets.
-- Membership checks must reject an unlisted group even when ANY(...) evaluates to NULL.
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, eligible_packing_groups, mixable_group_sets, approval_status, approved_by, approved_at, evidence_ref)
  values ('cnull', 1, 'NULL member', 'bulk_sweets', 4, 'tray', array['g1', null]::text[], '[]'::jsonb, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-NULL');
insert into public.product_packing_profiles (product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids, profile_version, approval_status, approved_by, approved_at, evidence_ref)
  values ('00000000-0000-0000-0000-000000001001', 'unlisted', 1, 'tray', '{cnull}', 2, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-NULL-P');
select is((public._t_eval('[{"p":"1001","q":4}]') -> 0 ->> 'code'), 'CARTON_GROUP_NOT_ELIGIBLE',
  'ineligible group fails closed even when approved configuration contains NULL array element');
update public.product_packing_profiles set approval_status = 'retired'
 where product_id = '00000000-0000-0000-0000-000000001001' and profile_version = 2;

-- Alternative approved carton configurations: the first option can be incomplete
-- while a later allowed capacity packs the same approved SKU without remainder.
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, eligible_packing_groups, mixable_group_sets, approval_status, approved_by, approved_at, evidence_ref)
values ('c10', 1, 'C10', 'bulk_sweets', 10, 'tray', '{g1}', '[]'::jsonb, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-C10');
insert into public.product_packing_profiles (product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids, profile_version, approval_status, approved_by, approved_at, evidence_ref)
values ('00000000-0000-0000-0000-000000001001', 'g1', 1, 'tray', '{c4,c10}', 3, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-ALT');
select lives_ok($$select public._t_order('[{"p":"1001","q":10}]')$$, '10 slots can fill an allowed c10 even when preferred c4 is incomplete');
select lives_ok($$select public._t_order('[{"p":"1001","q":4}]')$$, '4 slots still select the allowed c4 from multiple options');

-- staff amendment of a Buyer-origin order (line update / delete leave final state incomplete)
create or replace function public._t_amend() returns void language plpgsql as $f$
declare o uuid := public._t_order('[{"p":"1001","q":4}]');
begin
  update public.order_items set quantity = 3 where order_id = o;
  set constraints trg_order_items_carton_enforcement immediate;
end $f$;
select throws_ok($$select public._t_amend()$$, '23514', NULL, 'amending a complete order to an incomplete quantity is rejected at commit');
create or replace function public._t_amend_ok() returns void language plpgsql as $f$
declare o uuid := public._t_order('[{"p":"1001","q":4}]');
begin
  update public.order_items set quantity = 2 where order_id = o;
  insert into public.order_items (order_id, product_id, quantity, pack_size) values (o, '00000000-0000-0000-0000-000000001002', 2, 'tray');
  set constraints trg_order_items_carton_enforcement immediate; set constraints trg_order_items_carton_enforcement deferred;
end $f$;
select lives_ok($$select public._t_amend_ok()$$, 'a multi-statement amendment that ends complete is accepted');

-- An order_id-only reassignment must fire the deferred constraint and validate BOTH orders.
-- Old source becomes incomplete (2 slots); destination becomes full (4 slots).
create or replace function public._t_move_old_incomplete() returns void language plpgsql as $f$
declare src uuid := public._t_order('[{"p":"1001","q":2},{"p":"1002","q":2}]');
        dst uuid := public._t_order('[{"p":"1001","q":2}]', false, false);
begin
  update public.order_items set order_id = dst
   where order_id = src and product_id = '00000000-0000-0000-0000-000000001002';
  set constraints trg_order_items_carton_enforcement immediate;
end $f$;
select throws_ok($$select public._t_move_old_incomplete()$$, '23514', 'CARTON_ENFORCEMENT_VIOLATION',
  'order_id-only reassignment rejects an incomplete OLD order even when the NEW order is complete');

-- Source remains full (4 slots); destination becomes incomplete (6 slots).
create or replace function public._t_move_new_incomplete() returns void language plpgsql as $f$
declare src uuid := public._t_order('[{"p":"1001","q":4},{"p":"1002","q":4}]');
        dst uuid := public._t_order('[{"p":"1001","q":2}]', false, false);
begin
  update public.order_items set order_id = dst
   where order_id = src and product_id = '00000000-0000-0000-0000-000000001002';
  set constraints trg_order_items_carton_enforcement immediate;
end $f$;
select throws_ok($$select public._t_move_new_incomplete()$$, '23514', 'CARTON_ENFORCEMENT_VIOLATION',
  'order_id-only reassignment rejects an incomplete NEW order even when the OLD order is complete');

-- exceptions
select lives_ok($$select public._t_order('[{"p":"1001","q":1}]', true)$$, 'a recorded exception admits an otherwise incomplete order');
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', true);
select isnt((select public.grant_carton_enforcement_exception_v1('order', (select id from public.orders limit 1), 'approved by operations on call 123')), null, 'an authorised staff role can grant an audited exception');
select throws_ok($$select public.grant_carton_enforcement_exception_v1('order', (select id from public.orders limit 1), 'short')$$, '23514', NULL, 'an exception needs a substantive reason');
select throws_ok($$update public.orders set created_at = created_at - interval '2 days' where id = (select id from public.orders limit 1)$$, '23514', 'CARTON_ORDER_CREATED_AT_IMMUTABLE',
  'internal staff cannot backdate an order to bypass carton enforcement');
select throws_ok($$update public.orders set carton_line_revision = carton_line_revision + 500 where id = (select id from _t_verification_order)$$,
  '23514', 'CARTON_LINE_REVISION_INTERNAL_ONLY',
  'staff cannot forge a previously accepted carton revision');
reset role;
-- These two negative constraints use the privileged test role: authenticated direct writes are denied by ACL before a CHECK can run.
select throws_ok($$insert into public.carton_enforcement_exceptions (scope, ref_id, reason, granted_by) values ('order', gen_random_uuid(), E'  \t \n       ', '00000000-0000-0000-0000-00000000000d')$$, '23514', NULL, 'audit exceptions reject whitespace-only reason');
select throws_ok($$insert into public.carton_enforcement_exceptions (scope, ref_id, reason, granted_by) values ('order', gen_random_uuid(), repeat('x', 14) || repeat(' ', 50), '00000000-0000-0000-0000-00000000000d')$$, '23514', NULL, 'audit exceptions require at least 15 substantive non-whitespace characters');
select throws_ok($$update public.carton_enforcement_exceptions set reason = 'tampered with the audit trail'$$, '23514', NULL, 'exceptions are immutable');

-- production / packing updates on an existing incomplete order are not blocked
select lives_ok($$select 1 from (select public._t_order('[{"p":"1001","q":1}]', false, false) o) x; update public.order_items set actual_packed_qty = 1; set constraints trg_order_items_carton_enforcement immediate; set constraints trg_order_items_carton_enforcement deferred$$, 'non-commercial line updates (packing, production) do not re-trigger enforcement');

-- dispatch gate
select throws_ok($$select public._t_gate('[{"p":"1001","q":1}]', 'packed_ready')$$, '23514', 'CARTON_DISPATCH_GATE', 'an incomplete carton cannot reach packed_ready');
select throws_ok($$select public._t_gate('[{"p":"1001","q":3}]', 'dispatched')$$, '23514', 'CARTON_DISPATCH_GATE', 'an incomplete carton cannot reach dispatched');
select lives_ok($$select public._t_gate('[{"p":"1001","q":4}]', 'cleared_for_dispatch')$$, 'a complete carton can advance to cleared_for_dispatch');
select lives_ok($$select public._t_gate('[{"p":"1001","q":1}]', 'packed_ready', true)$$, 'a recorded exception admits an incomplete order at the dispatch gate');
select lives_ok($$select public._t_gate('[{"p":"1001","q":1}]', 'packed_ready', false, true)$$, 'legacy orders created before enforcement are not stranded mid-flight');
select lives_ok($$select public._t_gate('[{"p":"1001","q":1}]', 'in_production')$$, 'non-dispatch statuses are not gated');

-- legacy orders (created before enforced_from) can still be amended while enforcement is on (matches the dispatch gate)
select lives_ok($t$do $$ declare o uuid; begin o := public._t_order('[{"p":"1001","q":4}]', false, false);
  set local session_replication_role = replica; update public.orders set created_at = now() - interval '1 day' where id = o; set local session_replication_role = origin;
  update public.order_items set quantity = 1 where order_id = o; set constraints trg_order_items_carton_enforcement immediate; set constraints trg_order_items_carton_enforcement deferred; end $$ $t$,
  'amending a legacy order into an incomplete carton is not blocked by the deferred line trigger');

-- Snapshot stability: a submitted order uses stored pack_size commercial units; only a NEW quote consults live prices.
-- (uq_product_pricing_rules_product_channel is case-sensitive, so competing rows differ in the case of 'b2b'.)
reset role;
set local session_replication_role = replica;
update public.product_pricing_rules set uom = 'Tray ', approval_status = 'APPROVED' where product_id = '00000000-0000-0000-0000-000000001001' and price_channel = 'b2b';  -- matching unit, case-variant spelling
insert into public.product_pricing_rules (product_id, base_price, currency, uom, gst_rate, tax_inclusive, price_channel, approval_status, valid_from, valid_until, approved_at, updated_at)
  select '00000000-0000-0000-0000-000000001001'::uuid, x.price, 'INR', x.u, 5, true, x.ch, x.st, x.vf, x.vu, now(), now() + interval '1 hour' from (values
    (100::numeric, 'kg', 'B2B', 'approved', current_date - 5, current_date - 1),   -- expired
    (0::numeric,   'kg', 'B2b', 'approved', current_date,     null::date),         -- zero price
    (100::numeric, 'kg', 'b2B', 'approved', current_date + 3, null::date),         -- not yet effective
    (100::numeric, 'kg', 'b2c', 'approved', current_date,     null::date)          -- other channel
  ) x(price, u, ch, st, vf, vu);
set local session_replication_role = origin;
create temp table _t_saved_carton_order as select public._t_order('[{"p":"1001","q":4}]') as id;
select is((select lower(btrim(uom)) from (select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true)) z, lateral public.buyer_product_prices_v1() where product_id = '00000000-0000-0000-0000-000000001001' limit 1), 'tray', 'parity: buyer price unit ignores expired, zero-price, future and other-channel rules');
select ok(not (public._t_eval('[{"p":"1001","q":4}]') @> '[{"code":"CARTON_UNIT_MISMATCH"}]'::jsonb), 'parity: the evaluator also ignores them (no unit mismatch)');
set local session_replication_role = replica;
update public.product_pricing_rules set valid_from = current_date, valid_until = null where product_id = '00000000-0000-0000-0000-000000001001' and price_channel = 'b2B';
set local session_replication_role = origin;
select is((select lower(btrim(uom)) from (select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true)) z, lateral public.buyer_product_prices_v1() where product_id = '00000000-0000-0000-0000-000000001001' limit 1), 'kg', 'parity: once a competing rule is valid today with a later valid_from it wins for the buyer');
select ok(not (public.evaluate_order_carton_completeness_v1((select id from _t_saved_carton_order)) @> '[{"code":"CARTON_UNIT_MISMATCH"}]'::jsonb),
  'saved order retains its tray UOM even when a newer offer now prices the product in kg');
select lives_ok($$update public.orders set status = 'packed_ready' where id = (select id from _t_saved_carton_order)$$,
  're-pricing an item does not prevent an already-complete order from reaching packed_ready');
set local session_replication_role = replica;
update public.product_pricing_rules set valid_from = current_date - 5, valid_until = current_date - 1
 where product_id = '00000000-0000-0000-0000-000000001001' and lower(price_channel) = 'b2b';
set local session_replication_role = origin;
select lives_ok($$update public.orders set status = 'cleared_for_dispatch' where id = (select id from _t_saved_carton_order)$$,
  'expiry of every current B2B offer does not retroactively strand an existing full-carton order');

-- Historical accepted carton orders use their trusted verified revision and
-- original profile-version evidence, not a newly approved replacement profile.
create temp table _t_profile_frozen_order as
  select public._t_order('[{"p":"1001","q":4}]') as id;
select ok(exists(select 1 from public.carton_enforcement_verifications
  where order_id = (select id from _t_profile_frozen_order)
    and jsonb_array_length(profile_evidence) > 0),
  'accepted order persists its packing profile evidence');
insert into public.product_packing_profiles (
  product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids,
  profile_version, approval_status, approved_by, approved_at, evidence_ref
) values (
  '00000000-0000-0000-0000-000000001001', 'g1', 1, 'kg', '{c4,c10}',
  4, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-HISTORY'
);
select lives_ok($$update public.orders set status = 'packed_ready'
  where id = (select id from _t_profile_frozen_order)$$,
  'a replacement kg packing profile does not retroactively block a verified tray order');
-- OFF/ON toggles cannot revive a previously accepted snapshot after an
-- intervening commercial amendment; the saved revision must advance even
-- while policy enforcement is temporarily disabled.
create temp table _t_paused_policy_order as
  select public._t_order('[{"p":"1002","q":4}]') as id;
update public.carton_enforcement_settings set enabled = false;
update public.order_items set quantity = 3
  where order_id = (select id from _t_paused_policy_order);
select ok((
  select o.carton_line_revision > z.line_revision
    from public.orders o join public.carton_enforcement_verifications z on z.order_id = o.id
   where o.id = (select id from _t_paused_policy_order)
), 'an OFF-mode commercial amendment invalidates the previously accepted revision');
update public.carton_enforcement_settings set enabled = true;
select throws_ok($$update public.orders set status = 'packed_ready'
  where id = (select id from _t_paused_policy_order)$$,
  '23514', 'CARTON_DISPATCH_GATE',
  'reenabling the policy rejects an amended incomplete order despite its old accepted snapshot');

-- fail closed
set local session_replication_role = replica; delete from public.carton_enforcement_settings; set local session_replication_role = origin;
select throws_ok($$select public._t_order('[{"p":"1001","q":1}]')$$, '23514', NULL, 'a missing settings row enforces (fail closed)');

-- catalog
select ok(not has_function_privilege('authenticated', 'public.enforce_order_carton_completeness_v1()', 'execute') and not has_function_privilege('anon', 'public.evaluate_order_carton_completeness_v1(uuid)', 'execute'), 'helper functions are not executable by API roles');
select ok((select bool_and(coalesce(proconfig::text, '') like '%search_path=pg_catalog, public%') from pg_proc where proname in ('evaluate_order_carton_completeness_v1', 'enforce_order_carton_completeness_v1', 'grant_carton_enforcement_exception_v1')), 'security definer functions pin search_path');
select ok((select relforcerowsecurity and relrowsecurity from pg_class where oid = 'public.carton_enforcement_exceptions'::regclass), 'exceptions table has forced RLS');

select * from finish();
rollback;
