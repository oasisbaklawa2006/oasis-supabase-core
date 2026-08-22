begin;
-- Contract coverage for 20260822100000_3pgs_packing_material_catalogue.sql:
-- the insider-facing 3PGS packing-material catalogue view must show
-- packaging_material items at the 3PGS store (in and out of stock, the
-- latter carrying lead time from an open procurement requirement), and must
-- never show a sourced_ready_product (bought-out finished good) item, even
-- though both item_classes are valid at the 3PGS store per the existing
-- schema constraint.
select plan(8);

select has_view('public', 'b2b_3pgs_packing_material_catalogue', 'catalogue view exists');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('87000000-0000-0000-0000-000000000001', 'Outer Carton 3PGS', 'packaging', 'CARTON-3PGS-1', '4823', null),
  ('87000000-0000-0000-0000-000000000002', 'Out Of Stock Carton 3PGS', 'packaging', 'CARTON-3PGS-2', '4823', null),
  ('87000000-0000-0000-0000-000000000003', 'Bought-Out Sourced Good 3PGS', 'packaging', 'SOURCED-3PGS-1', '4823', null),
  ('87000000-0000-0000-0000-000000000004', 'Non-B2B-Relevant Carton 3PGS', 'packaging', 'CARTON-3PGS-NONREL', '4823', null),
  ('87000000-0000-0000-0000-000000000005', 'Packing Assembly Carton', 'packaging', 'CARTON-PACKASM-1', '4823', null);

insert into public.b2b_inventory_item_profiles (product_id, sku, item_class, primary_store_code, provenance_required, b2b_relevant) values
  ('87000000-0000-0000-0000-000000000001', 'CARTON-3PGS-1', 'packaging_material', '3PGS', false, true),
  ('87000000-0000-0000-0000-000000000002', 'CARTON-3PGS-2', 'packaging_material', '3PGS', false, true),
  ('87000000-0000-0000-0000-000000000003', 'SOURCED-3PGS-1', 'sourced_ready_product', '3PGS', true, true),
  ('87000000-0000-0000-0000-000000000004', 'CARTON-3PGS-NONREL', 'packaging_material', '3PGS', false, false),
  ('87000000-0000-0000-0000-000000000005', 'CARTON-PACKASM-1', 'packaging_material', 'PACKING_ASSEMBLY', false, true);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('87000000-0000-0000-0000-000000000001', 'CARTON-3PGS-1', '3PGS', 50);
-- CARTON-3PGS-2 deliberately has no stock balance row -- must still appear.

insert into public.b2b_procurement_requirements (
  requirement_number, source_type, source_reference, product_id, sku,
  destination_store_code, shortage_qty, status, expected_at, raised_by, correlation_id
) values (
  'PGTAP-CAT-PROC-1', 'manual', 'PGTAP-CAT-1', '87000000-0000-0000-0000-000000000002', 'CARTON-3PGS-2',
  '3PGS', 100, 'vendor_assigned', now() + interval '5 days', null, 'corr-cat-proc-1'
);

select is(
  (select count(*)::int from public.b2b_3pgs_packing_material_catalogue where sku = 'CARTON-3PGS-1'),
  1, 'in-stock packaging_material item appears in the catalogue'
);
select is(
  (select availability_status from public.b2b_3pgs_packing_material_catalogue where sku = 'CARTON-3PGS-2'),
  'unavailable', 'out-of-stock packaging_material item remains visible as unavailable'
);
select isnt(
  (select lead_time_expected_at from public.b2b_3pgs_packing_material_catalogue where sku = 'CARTON-3PGS-2'),
  null, 'out-of-stock item carries lead time from its open procurement requirement'
);
select is(
  (select count(*)::int from public.b2b_3pgs_packing_material_catalogue where sku = 'SOURCED-3PGS-1'),
  0, 'sourced_ready_product (bought-out finished good) never appears in the packing-material catalogue'
);
select is(
  (select count(*)::int from public.b2b_3pgs_packing_material_catalogue where sku = 'CARTON-3PGS-NONREL'),
  0, 'an item not marked b2b_relevant is excluded from the catalogue'
);
select is(
  (select count(*)::int from public.b2b_3pgs_packing_material_catalogue where sku = 'CARTON-PACKASM-1'),
  0, 'a packaging_material item at a store other than 3PGS is excluded from the catalogue'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
