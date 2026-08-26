begin;

-- Contract for migration 20260826093000_3pgs_staff_provisioning_role_parity.sql.
select plan(4);

select is(
  (select count(*)::integer from public.staff_provisionable_roles where role_key = 'store_3rd_party'),
  1,
  'STORE_3RD_PARTY exists exactly once in governed staff provisioning allowlist'
);

select ok(
  (select is_active from public.staff_provisionable_roles where role_key = 'store_3rd_party'),
  'STORE_3RD_PARTY is active for governed staff provisioning'
);

select ok(
  not (select requires_step_up from public.staff_provisionable_roles where role_key = 'store_3rd_party'),
  'STORE_3RD_PARTY follows ordinary operational-role step-up policy'
);

select ok(
  exists (
    select 1
    from pg_get_functiondef('public.can_manage_b2b_inventory(uuid)'::regprocedure) as f(definition)
    where upper(definition) like '%STORE_3RD_PARTY%'
  ),
  'existing 3PGS inventory authority still recognizes STORE_3RD_PARTY'
);

select * from finish();
rollback;