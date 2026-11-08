-- Rollback for 20261108113100_delivery_addresses_direct_write_hardening_v1.sql.
-- Restores the exact policies and grants observed in production on 2026-11-02 (policy text, TO public, anon/authenticated all privileges).
-- Re-opens the direct-write bypass: roll back only if a legitimate direct-write caller is found, and fix that caller first.
-- ONE transaction: all-or-nothing, so a partial earlier run (policy already exists) leaves the table exactly as it was.
begin;
create policy "Users can insert their company addresses" on public.delivery_addresses for insert
  with check (company_id in (select profiles.company_id from public.profiles where profiles.id = auth.uid()));
create policy "Users can insert company addresses" on public.delivery_addresses for insert
  with check (company_id in (select users.company_id from public.users where users.id = auth.uid()));
create policy "Users can update their company addresses" on public.delivery_addresses for update
  using (company_id in (select profiles.company_id from public.profiles where profiles.id = auth.uid()));
create policy "Users can delete their company addresses" on public.delivery_addresses for delete
  using (company_id in (select profiles.company_id from public.profiles where profiles.id = auth.uid()));
grant all on table public.delivery_addresses to anon, authenticated;
commit;
