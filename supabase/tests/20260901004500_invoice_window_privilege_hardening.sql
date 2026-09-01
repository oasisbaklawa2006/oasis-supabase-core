-- Contract for 20260901004500_invoice_window_privilege_hardening.sql.
-- Preserve the narrowed Finance/Exit projection privilege boundary.

select plan(2);

select ok(
  has_function_privilege('authenticated','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'authenticated internal callers retain Finance/Exit facts access'
);

select ok(
  not has_function_privilege('service_role','public.get_finance_exit_facts_v1(uuid)','EXECUTE'),
  'service_role cannot execute the internal Finance/Exit facts projection'
);

select * from finish();
