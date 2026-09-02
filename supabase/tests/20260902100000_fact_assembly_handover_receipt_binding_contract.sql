begin;
-- Contract coverage for 20260902100000_fact_assembly_handover_receipt_binding.sql.
select plan(3);

select has_function(
  'public',
  'create_b2b_inventory_receipt_from_assembly_handover',
  array['uuid','text','numeric','text','text'],
  '20260902100000 exposes the governed Assembly-handover receipt binding RPC'
);

select is(
  has_function_privilege(
    'authenticated',
    'public.create_b2b_inventory_receipt_from_assembly_handover(uuid,text,numeric,text,text)',
    'EXECUTE'
  ),
  true,
  '20260902100000 grants authenticated execution only through the governed RPC surface'
);

select is(
  has_table_privilege('authenticated', 'public.b2b_inventory_receipts', 'INSERT'),
  false,
  '20260902100000 preserves direct authenticated receipt INSERT denial'
);

select * from finish();
rollback;
