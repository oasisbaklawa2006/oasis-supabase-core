-- Contract for migration 20261120235600_factory_rgs_order_line_trace_authority.sql
BEGIN;
SELECT plan(23);
SELECT has_column('public','inventory_reservations','order_item_id',
  'Core RGS reservations now support typed original SO-line identity');
SELECT has_function('public','enforce_rgs_factory_line_reference_v1',
  'Factory reservation provenance enforcement exists');
SELECT has_function('public','bind_factory_production_job_line_v1',
  'Production job lineage propagation exists');
SELECT is(
  (SELECT count(*)::integer FROM pg_trigger
    WHERE tgname='trg_factory_rgs_line_reference' AND tgenabled='O'), 1,
  'line binding is enforced on every governed RGS reservation insert'
);
SELECT is(
  (SELECT count(*)::integer FROM pg_trigger
    WHERE tgname='trg_factory_production_job_line' AND tgenabled='O'), 1,
  'production job copies the same verified original SO-line'
);
SELECT ok(
  pg_get_functiondef('public.enforce_rgs_factory_line_reference_v1()'::regprocedure)
    LIKE '%FACTORY_ORDER_LINE_BINDING_MISMATCH%',
  'wrong order/product or excess quantity fails closed'
);
SELECT ok(
  pg_get_functiondef('public.enforce_rgs_factory_line_reference_v1()'::regprocedure)
    LIKE '%assert_active_operations_clearance_v1%',
  'governed line registration checks current Finance operations release'
);
SELECT ok(
  pg_get_functiondef('public.enforce_rgs_factory_line_reference_v1()'::regprocedure)
    LIKE '%LEGACY_ERP%',
  'historical ERP null-line rows are not guessed or rewritten'
);
SELECT is(
  has_table_privilege('authenticated','public.inventory_reservations','UPDATE'),false,
  'authenticated staff still cannot directly modify line FK'
);
SELECT is(
  has_function_privilege('authenticated','public.enforce_rgs_factory_line_reference_v1()','EXECUTE'),false,
  'trigger function cannot be invoked as an RPC by staff'
);
-- Reproducible behavioral check: two original SO lines contain the same SKU.
-- LEGACY_ERP orders cannot be newly created in production. The postgres-only
-- pgTAP fixture simulates a historical row inside a ROLLBACK-bound transaction:
-- disable ONLY the historical INSERT guard for the seed row and restore it
-- immediately. Other status, Finance, reservation and lineage guards stay live.
-- No application role receives authority to create legacy-origin orders.
INSERT INTO public.products (id,name,category,sku,hsn_code,production_department)
VALUES ('5e000000-0000-0000-0000-000000000011', 'Factory F07 Same SKU', 'sweets',
        'FACT-F07-SKU', '1905', 'arabic_sweets');
ALTER TABLE public.orders DISABLE TRIGGER trg_orders_historical_legacy_erp_origin;
INSERT INTO public.orders (id,order_number,tracking_token,order_origin)
VALUES ('5e000000-0000-0000-0000-000000000021','FACT-F07-SO','fact-f07-token','LEGACY_ERP');
ALTER TABLE public.orders ENABLE TRIGGER trg_orders_historical_legacy_erp_origin;
INSERT INTO public.order_items (id,order_id,product_id,quantity) VALUES
 ('5e000000-0000-0000-0000-000000000031','5e000000-0000-0000-0000-000000000021',
  '5e000000-0000-0000-0000-000000000011',10),
 ('5e000000-0000-0000-0000-000000000032','5e000000-0000-0000-0000-000000000021',
  '5e000000-0000-0000-0000-000000000011',20);
INSERT INTO public.inventory_reservations
 (id,reservation_number,order_id,product_id,sku,requested_qty,correlation_id,demand_source_type,demand_reference)
VALUES
 ('5e000000-0000-0000-0000-000000000041','FACT-F07-RES1',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'FACT-F07-SKU',10,'FACT-F07-CORR-1','b2b','order_item:5e000000-0000-0000-0000-000000000031'),
 ('5e000000-0000-0000-0000-000000000042','FACT-F07-RES2',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'FACT-F07-SKU',20,'FACT-F07-CORR-2','b2b','order_item:5e000000-0000-0000-0000-000000000032');

SELECT is(
 (SELECT order_item_id FROM public.inventory_reservations WHERE id='5e000000-0000-0000-0000-000000000041'),
 '5e000000-0000-0000-0000-000000000031'::uuid,
 'first same-SKU reservation is bound to original SO line 1'
);
SELECT is(
 (SELECT order_item_id FROM public.inventory_reservations WHERE id='5e000000-0000-0000-0000-000000000042'),
 '5e000000-0000-0000-0000-000000000032'::uuid,
 'second same-SKU reservation is bound to original SO line 2'
);

INSERT INTO public.production_jobs
 (id,order_id,product_id,department,reservation_id,assigned_qty,correlation_id)
VALUES
 ('5e000000-0000-0000-0000-000000000051',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'ARABIC_SWEETS','5e000000-0000-0000-0000-000000000041',10,'FACT-F07-JOB-1'),
 ('5e000000-0000-0000-0000-000000000052',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'ARABIC_SWEETS','5e000000-0000-0000-0000-000000000042',20,'FACT-F07-JOB-2');

SELECT is(
 (SELECT order_item_id FROM public.production_jobs WHERE id='5e000000-0000-0000-0000-000000000051'),
 '5e000000-0000-0000-0000-000000000031'::uuid,
 'first production job carries the original first line ID, not a same-SKU guess'
);
SELECT is(
 (SELECT order_item_id FROM public.production_jobs WHERE id='5e000000-0000-0000-0000-000000000052'),
 '5e000000-0000-0000-0000-000000000032'::uuid,
 'second production job carries the distinct second line ID'
);

SELECT throws_like($
 INSERT INTO public.inventory_reservations
  (reservation_number,order_id,product_id,sku,requested_qty,correlation_id,demand_reference)
 VALUES ('FACT-F07-BAD-QTY','5e000000-0000-0000-0000-000000000021',
  '5e000000-0000-0000-0000-000000000011','FACT-F07-SKU',11,'FACT-F07-BAD-QTY-CORR',
  'order_item:5e000000-0000-0000-0000-000000000031')
$,'%FACTORY_ORDER_LINE_BINDING_MISMATCH%',
 'reservation quantity above original SO line is rejected');

SELECT throws_like($
 INSERT INTO public.inventory_reservations
  (reservation_number,order_id,product_id,sku,requested_qty,correlation_id,demand_reference)
 VALUES ('FACT-F07-DUP','5e000000-0000-0000-0000-000000000021',
  '5e000000-0000-0000-0000-000000000011','FACT-F07-SKU',10,'FACT-F07-DUP-CORR',
  'order_item:5e000000-0000-0000-0000-000000000031')
$,'%uq_rgs_b2b_source_line_location%',
 'a second reservation on the same SO line+location cannot silently duplicate allocation');

SELECT throws_like($
 INSERT INTO public.production_jobs
  (order_id,order_item_id,product_id,department,reservation_id,assigned_qty,correlation_id)
 VALUES ('5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000032',
  '5e000000-0000-0000-0000-000000000011','ARABIC_SWEETS',
  '5e000000-0000-0000-0000-000000000041',10,'FACT-F07-WRONG-LINE')
$,'%FACTORY_PRODUCTION_ORDER_LINE_MISMATCH%',
 'caller cannot bind a production job to another same-SKU SO line');

SELECT throws_like($
 INSERT INTO public.inventory_reservations
  (reservation_number,order_id,product_id,sku,requested_qty,correlation_id,demand_source_type,order_item_id)
 VALUES ('FACT-F07-BAD-SOURCE',NULL,'5e000000-0000-0000-0000-000000000011','FACT-F07-SKU',1,
  'FACT-F07-BAD-SOURCE-CORR','internal','5e000000-0000-0000-0000-000000000031')
$,'%FACTORY_ORDER_LINE_SOURCE_MUST_BE_B2B%',
 'internal demand cannot impersonate an original customer order line');

-- Regression: a historical reservation without exact line evidence is valid,
-- but neither a new job nor an existing job may attribute that reservation
-- to another SO line. A non-reservation quick-log job remains independent.
INSERT INTO public.inventory_reservations
 (id,reservation_number,order_id,product_id,sku,requested_qty,correlation_id,demand_source_type)
VALUES
 ('5e000000-0000-0000-0000-000000000043','FACT-F07-LEGACY',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'FACT-F07-SKU',1,'FACT-F07-LEGACY-CORR','b2b');
SELECT is(
 (SELECT order_item_id FROM public.inventory_reservations WHERE id='5e000000-0000-0000-0000-000000000043'),
 NULL::uuid,
 'historical unanchored reservation preserves NULL original SO line'
);
SELECT throws_like($
 INSERT INTO public.production_jobs
  (order_id,order_item_id,product_id,department,reservation_id,assigned_qty,correlation_id)
 VALUES ('5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000031',
  '5e000000-0000-0000-0000-000000000011','ARABIC_SWEETS',
  '5e000000-0000-0000-0000-000000000043',1,'FACT-F07-UNANCHORED-INSERT')
$,'%FACTORY_PRODUCTION_ORDER_LINE_MISMATCH%',
 'reservation-linked insert rejects an unrelated line when reservation lineage is NULL');
SELECT throws_like($
 UPDATE public.production_jobs
    SET reservation_id = '5e000000-0000-0000-0000-000000000043'
  WHERE id = '5e000000-0000-0000-0000-000000000051'
$,'%FACTORY_PRODUCTION_ORDER_LINE_MISMATCH%',
 'reassigning an anchored job to unanchored reservation cannot retain stale line');

INSERT INTO public.production_jobs
 (id,order_id,product_id,department,reservation_id,assigned_qty,correlation_id)
VALUES
 ('5e000000-0000-0000-0000-000000000053',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000011',
  'ARABIC_SWEETS','5e000000-0000-0000-0000-000000000043',1,'FACT-F07-UNANCHORED-VALID');
SELECT is(
 (SELECT order_item_id FROM public.production_jobs WHERE id='5e000000-0000-0000-0000-000000000053'),
 NULL::uuid,
 'legitimate historical reservation-linked job without line remains supported'
);
INSERT INTO public.production_jobs
 (id,order_id,order_item_id,product_id,department,assigned_qty,correlation_id)
VALUES
 ('5e000000-0000-0000-0000-000000000054',
  '5e000000-0000-0000-0000-000000000021','5e000000-0000-0000-0000-000000000031',
  '5e000000-0000-0000-0000-000000000011','ARABIC_SWEETS',1,'FACT-F07-QUICK-LOG');
SELECT is(
 (SELECT order_item_id FROM public.production_jobs WHERE id='5e000000-0000-0000-0000-000000000054'),
 '5e000000-0000-0000-0000-000000000031'::uuid,
 'independent quick-log job is not modified by reservation lineage trigger'
);

SELECT * FROM finish();
ROLLBACK;
