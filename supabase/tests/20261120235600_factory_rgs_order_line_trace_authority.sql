-- Contract for migration 20261120235600_factory_rgs_order_line_trace_authority.sql
BEGIN;
SELECT plan(10);
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
SELECT * FROM finish();
ROLLBACK;
