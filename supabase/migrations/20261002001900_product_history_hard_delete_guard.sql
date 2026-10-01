-- Final certification: preserve historical product identity.
-- Hard delete is only permitted for an inactive product that has never entered
-- commercial, production, publication, inventory or dispatch history.
begin;

create or replace function public.guard_referenced_product_hard_delete_v1()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if coalesce(old.is_active,false) then
    raise exception 'PRODUCT_HARD_DELETE_FORBIDDEN: deactivate/archive active product first'
      using errcode='23503';
  end if;

  if exists (select 1 from public.order_items x where x.product_id=old.id)
     or exists (select 1 from public.production_jobs x where x.product_id=old.id)
     or exists (select 1 from public.catalogue_versions x where x.product_id=old.id)
     or exists (select 1 from public.daily_production_logs x where x.product_id=old.id)
     or exists (select 1 from public.inventory_adjustments x where x.product_id=old.id)
     or exists (select 1 from public.packing_lists x where x.product_id=old.id)
     or exists (select 1 from public.order_returns x where x.product_id=old.id)
     or exists (select 1 from public.production_rgs_transfers x where x.product_id=old.id)
     or exists (select 1 from public.customer_quotation_lines x where x.product_id=old.id)
     or exists (select 1 from public.whatsapp_sales_order_drafts x where x.resolved_product_id=old.id)
  then
    raise exception 'PRODUCT_HARD_DELETE_FORBIDDEN: referenced product must be archived/deactivated to preserve historical identity'
      using errcode='23503';
  end if;

  return old;
end;
$$;

revoke all on function public.guard_referenced_product_hard_delete_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists trg_guard_referenced_product_hard_delete_v1 on public.products;
create trigger trg_guard_referenced_product_hard_delete_v1
before delete on public.products
for each row execute function public.guard_referenced_product_hard_delete_v1();

comment on function public.guard_referenced_product_hard_delete_v1() is
  'Prevents hard deletion of active or historically referenced products; use deactivation/archive so order, production, publication and trace identity remain intelligible.';

commit;
