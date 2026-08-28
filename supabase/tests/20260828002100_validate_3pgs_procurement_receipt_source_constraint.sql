begin;
-- Contract coverage for 20260828002100_validate_3pgs_procurement_receipt_source_constraint.sql.

select plan(1);

select is(
  (select convalidated
     from pg_constraint
    where conrelid = 'public.b2b_inventory_receipts'::regclass
      and conname = 'b2b_inventory_receipts_source_reference_check'),
  true,
  '3PGS procurement receipt source constraint is validated in its separate migration transaction'
);

select * from finish();
rollback;
