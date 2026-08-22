begin;
-- Contract coverage for 20260822090000_3pgs_store_role_parity.sql:
-- STORE_3RD_PARTY must now pass can_manage_b2b_inventory / can_receive_b2b_inventory,
-- and every previously-covered role must remain unaffected.
select plan(6);

insert into public.users (id, role) values
  ('47000000-0000-0000-0000-000000000001', 'STORE_3RD_PARTY'),
  ('47000000-0000-0000-0000-000000000002', 'STORE_INCHARGE'),
  ('47000000-0000-0000-0000-000000000003', 'CUSTOMER');

select is(
  public.can_manage_b2b_inventory('47000000-0000-0000-0000-000000000001'::uuid),
  true, 'STORE_3RD_PARTY can now call governed 3PGS management RPCs'
);
select is(
  public.can_receive_b2b_inventory('47000000-0000-0000-0000-000000000001'::uuid),
  true, 'STORE_3RD_PARTY can now call governed 3PGS receipt/acknowledgement RPCs'
);
select is(
  public.can_manage_b2b_inventory('47000000-0000-0000-0000-000000000002'::uuid),
  true, 'STORE_INCHARGE authority is unchanged by this migration'
);
select is(
  public.can_receive_b2b_inventory('47000000-0000-0000-0000-000000000002'::uuid),
  true, 'STORE_INCHARGE receive authority is unchanged by this migration'
);
select is(
  public.can_manage_b2b_inventory('47000000-0000-0000-0000-000000000003'::uuid),
  false, 'CUSTOMER remains excluded from governed 3PGS management RPCs'
);
select is(
  public.can_receive_b2b_inventory('47000000-0000-0000-0000-000000000003'::uuid),
  false, 'CUSTOMER remains excluded from governed 3PGS receipt/acknowledgement RPCs'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
