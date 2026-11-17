-- Contract test for 20261117150200_genie_cart_receipt_forward_parity_v2_forward.sql; also validates preview ledger marker 20261116140000_genie_cart_receipt_forward_parity_v2.sql.
-- Contract test for 20261116140000_genie_cart_receipt_forward_parity_v2.sql.
-- Source and preview parity verification; pgTAP executes in rollback.
begin;
select plan(5);

select ok((select count(*)=1 from information_schema.columns
where table_schema='public' and table_name='customer_genie_cart_operations'
and column_name='existing_quantity'),'operation receipt retains original Cart quantity');

select ok((select is_nullable='NO' from information_schema.columns
where table_schema='public' and table_name='customer_genie_cart_operations'
and column_name='existing_quantity'),'original Cart quantity is not nullable');

select ok(exists(select 1 from pg_constraint c
where c.conrelid='public.customer_genie_cart_operations'::regclass
and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%existing_quantity%'),
'original Cart quantity is constrained positive');

select ok((select position('v_old.existing_quantity' in p.prosrc)>0 and
  position('l.quantity = v_old.existing_quantity' in p.prosrc)>0
from pg_proc p
where p.oid='public.add_customer_order_draft_line_genie_v2(uuid,numeric,uuid)'::regprocedure),
'operation replay uses original authoritative conflict quantity');

select ok(not has_function_privilege('anon',
'public.add_customer_order_draft_line_genie_v2(uuid,numeric,uuid)','EXECUTE'),
'original operation RPC stays revoked from anon');

select * from finish();
rollback;
