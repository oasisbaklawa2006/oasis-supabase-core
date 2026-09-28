begin;
-- Contract for 20260915210000_supabase_advisor_security_hardening.sql
select plan(15);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.staff_provisionable_roles'::regclass),
  'staff provisioning allowlist has RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.staff_provisionable_roles', 'SELECT')
  and not has_table_privilege('authenticated', 'public.staff_provisionable_roles', 'SELECT'),
  'client roles cannot directly read the staff provisioning allowlist'
);

select ok(
  has_table_privilege('service_role', 'public.staff_provisionable_roles', 'SELECT'),
  'governed service-role provisioning can still read the allowlist'
);

select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_dispatch_delete()'::regprocedure), 'prevent_b2b_dispatch_delete pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.protect_b2b_dispatch_line_identity()'::regprocedure), 'protect_b2b_dispatch_line_identity pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_dispatch_append_only_update()'::regprocedure), 'prevent_b2b_dispatch_append_only_update pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.validate_b2b_dispatch_consignment_transition()'::regprocedure), 'validate_b2b_dispatch_consignment_transition pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.touch_b2b_dispatch_updated_at()'::regprocedure), 'touch_b2b_dispatch_updated_at pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_return_arrival_delete()'::regprocedure), 'prevent_b2b_return_arrival_delete pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.protect_b2b_return_receipt_evidence()'::regprocedure), 'protect_b2b_return_receipt_evidence pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_return_decision_update()'::regprocedure), 'prevent_b2b_return_decision_update pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_dispatch_shipping_correction_mutation()'::regprocedure), 'prevent_b2b_dispatch_shipping_correction_mutation pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.guard_b2b_dispatch_consignment_governed_fields()'::regprocedure), 'guard_b2b_dispatch_consignment_governed_fields pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.prevent_b2b_dispatch_priority_override_mutation()'::regprocedure), 'prevent_b2b_dispatch_priority_override_mutation pins an empty search_path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.is_canonical_tv_group(text)'::regprocedure), 'is_canonical_tv_group pins an empty search_path');

select finish();
rollback;
