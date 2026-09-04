-- Contract for 20260904030200_point29_blocker_hardening_reconcile.sql
begin;

select plan(2);

select ok(
  NOT has_function_privilege(
    'authenticated',
    'public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid)',
    'EXECUTE'
  ),
  'hardening reconcile removes authenticated EXECUTE on atomic approval RPC'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid)',
    'EXECUTE'
  ),
  'hardening reconcile preserves service_role EXECUTE on atomic approval RPC'
);

select * from finish();
rollback;
