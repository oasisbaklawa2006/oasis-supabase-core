-- Contract test for 20261117010100_genie_cart_checkout_lock_and_receipt_fk_index.sql.
-- Source-level lock sequence; physically concurrent checkout/device UAT still required.
begin;
select plan(5);

select ok(exists(select 1 from pg_indexes where schemaname='public'
and tablename='customer_genie_cart_operations'
and indexname='customer_genie_cart_operations_draft_line_id_idx'
and indexdef like '%USING btree (draft_line_id)%'),
'ON DELETE SET NULL receipt FK has a draft_line_id index');

select ok((select position('pg_advisory_xact_lock' in p.prosrc)>0
and position('pg_advisory_xact_lock' in p.prosrc)
  < position('for update of d' in p.prosrc)
and position('for update of d' in p.prosrc)
  < position('for update of l' in p.prosrc)
from pg_proc p where p.oid='public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)'::regprocedure),
'Genie CAS locks company, then checkout draft, then Cart line');

select ok((select position('d.status = ''active''' in p.prosrc)>0 and
position('v_line.quantity is distinct from p_expected_quantity' in p.prosrc)>0
from pg_proc p where p.oid='public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)'::regprocedure),
'CAS checks active checkout status and exact previously read quantity');

select ok((select position('update_customer_order_draft_line_v1(p_line_id, p_quantity)' in p.prosrc)>0
from pg_proc p where p.oid='public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)'::regprocedure),
'CAS delegates business validation, audit and readiness to current v1 authority');

select ok(not has_function_privilege('anon',
'public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)','EXECUTE'),
'new CAS function remains unavailable to anon');

select * from finish();
rollback;
