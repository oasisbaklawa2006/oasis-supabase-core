begin;
-- Contract coverage for 20260902082001_validate_fact_assembly_handover_receipt_binding.sql.

select plan(1);

select is(
  (select convalidated
     from pg_constraint
    where conrelid = 'public.b2b_inventory_receipts'::regclass
      and conname = 'b2b_inventory_receipts_assembly_handover_reference_check'),
  true,
  'Assembly handover receipt lineage constraint is validated in its separate migration transaction'
);

select * from finish();
rollback;
