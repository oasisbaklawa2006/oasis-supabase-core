-- Final certification: Security Gate is read-only for commercial order truth.
-- Gate roles need order/customer facts for exit verification, but must never mutate
-- Sales/Finance/commercial order records through generic staff or buyer RLS paths.
begin;

drop policy if exists "Staff update non-governed order fields" on public.orders;
create policy "Staff update non-governed order fields"
  on public.orders for update to authenticated
  using (
    public.is_internal_staff(auth.uid())
    and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
      ('SALES_EXECUTIVE','GATE_SECURITY','SECURITY_CONTROL')
  )
  with check (
    public.is_internal_staff(auth.uid())
    and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
      ('SALES_EXECUTIVE','GATE_SECURITY','SECURITY_CONTROL')
  );

drop policy if exists "Buyers insert own company orders" on public.orders;
create policy "Buyers insert own company orders"
  on public.orders for insert to public
  with check (
    (
      not coalesce(public.is_internal_staff(auth.uid()),false)
      and company_id = (
        select u.company_id from public.users u where u.id=auth.uid() limit 1
      )
    )
    or (
      public.is_internal_staff(auth.uid())
      and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
        ('GATE_SECURITY','SECURITY_CONTROL')
    )
    or upper(coalesce(public.get_user_role(auth.uid()),'')) in ('ADMIN','SUPER_ADMIN')
  );

drop policy if exists "Buyers insert own orders" on public.orders;
create policy "Buyers insert own orders"
  on public.orders for insert to authenticated
  with check (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and company_id is not null
    and company_id = (
      select u.company_id from public.users u where u.id=auth.uid() limit 1
    )
  );

drop policy if exists "Buyers update own draft orders" on public.orders;
create policy "Buyers update own draft orders"
  on public.orders for update to authenticated
  using (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and status='draft'
    and company_id = (
      select u.company_id from public.users u where u.id=auth.uid() limit 1
    )
  )
  with check (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and company_id = (
      select u.company_id from public.users u where u.id=auth.uid() limit 1
    )
  );

drop policy if exists "buyer_update_submitted_order_receipt" on public.orders;
create policy "buyer_update_submitted_order_receipt"
  on public.orders for update to authenticated
  using (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and company_id = (
      select u.company_id from public.users u where u.id=auth.uid() limit 1
    )
    and status in ('submitted','under_review')
  )
  with check (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and company_id = (
      select u.company_id from public.users u where u.id=auth.uid() limit 1
    )
    and status in ('submitted','under_review')
  );

drop policy if exists "Staff full access order_items" on public.order_items;
create policy "Staff full access order_items"
  on public.order_items for all to authenticated
  using (
    public.is_internal_staff(auth.uid())
    and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
      ('SALES_EXECUTIVE','GATE_SECURITY','SECURITY_CONTROL')
  )
  with check (
    public.is_internal_staff(auth.uid())
    and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
      ('SALES_EXECUTIVE','GATE_SECURITY','SECURITY_CONTROL')
  );

drop policy if exists "Buyers insert own order_items" on public.order_items;
create policy "Buyers insert own order_items"
  on public.order_items for insert to public
  with check (
    (
      not coalesce(public.is_internal_staff(auth.uid()),false)
      and order_id in (
        select o.id
        from public.orders o
        join public.users u on u.id=auth.uid()
        where o.company_id=u.company_id
      )
    )
    or (
      public.is_internal_staff(auth.uid())
      and upper(coalesce(public.get_user_role(auth.uid()),'')) not in
        ('GATE_SECURITY','SECURITY_CONTROL')
    )
    or upper(coalesce(public.get_user_role(auth.uid()),'')) in ('ADMIN','SUPER_ADMIN')
  );

drop policy if exists "Buyers update own order_items" on public.order_items;
create policy "Buyers update own order_items"
  on public.order_items for update to authenticated
  using (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and order_id in (
      select o.id from public.orders o
      where o.company_id=(select u.company_id from public.users u where u.id=auth.uid() limit 1)
    )
  )
  with check (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and order_id in (
      select o.id from public.orders o
      where o.company_id=(select u.company_id from public.users u where u.id=auth.uid() limit 1)
    )
  );

drop policy if exists "Buyers delete own order_items" on public.order_items;
create policy "Buyers delete own order_items"
  on public.order_items for delete to authenticated
  using (
    not coalesce(public.is_internal_staff(auth.uid()),false)
    and order_id in (
      select o.id from public.orders o
      where o.company_id=(select u.company_id from public.users u where u.id=auth.uid() limit 1)
    )
  );

commit;
