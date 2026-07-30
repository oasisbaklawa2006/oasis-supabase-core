-- Harden critical master-data tables that previously granted unrestricted
-- authenticated writes. Read access is preserved for authenticated catalogue
-- consumers; mutations are restricted to administrators. Users retain limited
-- self-service profile updates, while privilege-bearing fields are protected.

create or replace function public.protect_user_privilege_fields()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() = 'service_role' or public.is_admin() then
    return new;
  end if;

  if auth.uid() is null or old.id is distinct from auth.uid() or new.id is distinct from old.id then
    raise exception 'user profile update not permitted';
  end if;

  if new.company_id is distinct from old.company_id
     or new.role is distinct from old.role
     or new.department is distinct from old.department
     or new.designation is distinct from old.designation
     or new.is_active is distinct from old.is_active
     or new.invite_status is distinct from old.invite_status
     or new.commission_rate_percentage is distinct from old.commission_rate_percentage
     or new.is_sales_executive is distinct from old.is_sales_executive
     or new.deleted_at is distinct from old.deleted_at
     or new.created_at is distinct from old.created_at
     or new.joined_at is distinct from old.joined_at then
    raise exception 'privileged user fields require administrator authority';
  end if;

  return new;
end;
$$;

revoke all on function public.protect_user_privilege_fields() from public, anon, authenticated;
grant execute on function public.protect_user_privilege_fields() to service_role;

drop trigger if exists trg_protect_user_privilege_fields on public.users;
create trigger trg_protect_user_privilege_fields
before update on public.users
for each row execute function public.protect_user_privilege_fields();

-- Remove the permissive legacy policies.
drop policy if exists "OASIS_ADMIN_FULL_CONTROL" on public.users;
drop policy if exists "OASIS_ADMIN_FULL_CONTROL" on public.products;
drop policy if exists "OASIS_AUTHENTICATED_FULL_ACCESS" on public.categories;
drop policy if exists "OASIS_AUTHENTICATED_FULL_ACCESS" on public.product_variants;
drop policy if exists "Authenticated write media" on public.product_media;

-- Users: self-service reads/updates plus administrator management.
drop policy if exists "Admins can update users" on public.users;
drop policy if exists "Admins can view all users" on public.users;

create policy "Users read self or admins read all"
on public.users
for select
to authenticated
using (public.is_admin() or id = auth.uid());

create policy "Users update self or admins update all"
on public.users
for update
to authenticated
using (public.is_admin() or id = auth.uid())
with check (public.is_admin() or id = auth.uid());

create policy "Admins insert users"
on public.users
for insert
to authenticated
with check (public.is_admin());

create policy "Admins delete users"
on public.users
for delete
to authenticated
using (public.is_admin());

-- Catalogue master tables: authenticated reads remain available, while direct
-- writes require administrator authority. Governed catalogue approval RPCs are
-- SECURITY DEFINER and continue to operate through reviewer permissions.
create policy "Authenticated read products"
on public.products
for select
to authenticated
using (true);

create policy "Admins insert products"
on public.products
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update products"
on public.products
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins delete products"
on public.products
for delete
to authenticated
using (public.is_admin());

create policy "Authenticated read categories"
on public.categories
for select
to authenticated
using (true);

create policy "Admins insert categories"
on public.categories
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update categories"
on public.categories
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins delete categories"
on public.categories
for delete
to authenticated
using (public.is_admin());

create policy "Authenticated read product variants"
on public.product_variants
for select
to authenticated
using (true);

create policy "Admins insert product variants"
on public.product_variants
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update product variants"
on public.product_variants
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins delete product variants"
on public.product_variants
for delete
to authenticated
using (public.is_admin());

create policy "Authenticated read product media"
on public.product_media
for select
to authenticated
using (true);

create policy "Admins insert product media"
on public.product_media
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update product media"
on public.product_media
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins delete product media"
on public.product_media
for delete
to authenticated
using (public.is_admin());

comment on function public.protect_user_privilege_fields() is
  '20260730123000_harden_critical_master_table_rls: prevents non-admin self-service updates from changing role, company, activation, employment, commission, or deletion fields.';
