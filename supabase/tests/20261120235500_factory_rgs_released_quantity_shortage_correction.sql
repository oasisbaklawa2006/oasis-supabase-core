-- Factory F09 source-contract assertions and transaction-safe negative gates.
BEGIN;
SELECT plan(8);
SELECT has_function('public','create_production_shortage_demand',
  array['uuid','text','text','text'],'RGS shortage authority remains the original RPC');
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  LIKE '%v_reservation.requested_qty - v_reservation.reserved_qty%',
  'shortage subtracts currently reserved stock'
);
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  LIKE '%- v_reservation.fulfilled_qty%',
  'shortage subtracts fulfilled stock'
);
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  NOT LIKE '%- v_reservation.released_qty%',
  'released history is NOT double-subtracted'
);
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  LIKE '%reservation_status NOT IN%',
  'terminal reservation status blocks demand generation'
);
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  LIKE '%FOR UPDATE%',
  'concurrent reservation reads retain the existing row lock'
);
SELECT ok(
  pg_get_functiondef('public.create_production_shortage_demand(uuid,text,text,text)'::regprocedure)
  LIKE '%status NOT IN (%',
  'existing open-job deduplication retained'
);
SELECT is(
  has_table_privilege('authenticated','public.production_jobs','INSERT'), false,
  'authenticated cannot bypass the production-job RPC with a direct insert'
);
SELECT * FROM finish();
ROLLBACK;
