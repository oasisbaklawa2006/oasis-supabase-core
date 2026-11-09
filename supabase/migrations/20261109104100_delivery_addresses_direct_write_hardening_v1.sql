-- Governed-write hardening for public.delivery_addresses (RELEASE AFTER 20261109104000, which provides the governed RPCs).
--
-- Demonstrated problem (reproduced 2026-11-03 on the Supabase Postgres 17 image with the production policies and ACL; evidence in
-- docs/delivery-addresses-hardening/README.md): anon and authenticated hold INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN on this
-- table and four write policies (all TO public) let ANY profile row of a company write that company's addresses directly through PostgREST.
-- Cross-tenant writes are already denied by RLS and are not changed here. What is bypassed is the governed RPC path:
--   - users who are NOT eligible Buyers (pending, rejected, or in a frozen company) can insert, edit and delete addresses;
--   - customer_upsert_delivery_address_v1 validation is skipped (blank / 10,000-character / control-character fields, forged user_id,
--     several default addresses per company);
--   - TRUNCATE (any of anon/authenticated, ignoring RLS) empties the table for every tenant when the caller holds a SQL connection.
--
-- Change: drop the four WRITE policies and revoke every write-type privilege from anon and authenticated. Both SELECT policies and the
-- authenticated SELECT privilege are kept (reads are unchanged); service_role keeps all of its privileges; the governed RPCs are
-- definer-rights and owned by the table owner, so they keep working (RLS is not FORCEd).
-- The Buyer app (main and PR #69) writes addresses only through the RPCs; Central only reads this table; Core scripts use service_role.
--
-- Reversible: the rollback file restores the exact production policies and grants.

do $$
declare
  v_table_owner name;
  r record;
begin
  select pg_get_userbyid(c.relowner) into v_table_owner from pg_class c where c.oid = 'public.delivery_addresses'::regclass;
  for r in
    select sig from (values
      ('public.customer_delivery_addresses_v1()'),
      ('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'),
      ('public.customer_delete_delivery_address_v1(uuid)'),
      ('public.customer_saved_transporters_v1()'),
      ('public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)'),
      ('public.customer_delete_saved_transporter_v1(uuid)')
    ) v(sig)
  loop
    if to_regprocedure(r.sig) is null then
      raise exception 'MIGRATION_ORDER_VIOLATION: governed RPC % (20261109104000) must exist before direct writes are revoked', r.sig;
    end if;
    if not exists (select 1 from pg_proc p where p.oid = to_regprocedure(r.sig) and p.prosecdef and pg_get_userbyid(p.proowner) = v_table_owner) then
      raise exception 'HARDENING_PRECONDITION_FAILED: % must be definer-rights and owned by the table owner (%) or it would lose write access', r.sig, v_table_owner;
    end if;
  end loop;
  if (select c.relforcerowsecurity from pg_class c where c.oid = 'public.delivery_addresses'::regclass) then
    raise exception 'HARDENING_PRECONDITION_FAILED: delivery_addresses has FORCE ROW LEVEL SECURITY; definer RPC writes would be blocked';
  end if;
end $$;

drop policy if exists "Users can insert their company addresses" on public.delivery_addresses;
drop policy if exists "Users can insert company addresses" on public.delivery_addresses;
drop policy if exists "Users can update their company addresses" on public.delivery_addresses;
drop policy if exists "Users can delete their company addresses" on public.delivery_addresses;

revoke all on table public.delivery_addresses from anon;
revoke all on table public.delivery_addresses from authenticated;
grant select on table public.delivery_addresses to authenticated;
