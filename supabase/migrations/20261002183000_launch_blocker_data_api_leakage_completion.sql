-- Target 1 completion: enforce the approved raw-data boundary end-to-end.
begin;

alter table public.products enable row level security;
alter table public.product_pricing_rules enable row level security;
alter table public.product_moq_rules enable row level security;
alter table public.dispatches enable row level security;
alter table public.ols_orders_cache enable row level security;
alter table public.ols_products_cache enable row level security;
alter table public.ols_production_batches enable row level security;
alter table public.ols_production_labels enable row level security;

drop policy if exists "Authenticated read products" on public.products;
drop policy if exists "Internal staff read products" on public.products;
create policy "Internal staff read products"
on public.products for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Authenticated read product_pricing_rules" on public.product_pricing_rules;
drop policy if exists "Internal staff read product_pricing_rules" on public.product_pricing_rules;
create policy "Internal staff read product_pricing_rules"
on public.product_pricing_rules for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Authenticated read product_moq_rules" on public.product_moq_rules;
drop policy if exists "Internal staff read product_moq_rules" on public.product_moq_rules;
create policy "Internal staff read product_moq_rules"
on public.product_moq_rules for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists ols_auth_read on public.ols_orders_cache;
drop policy if exists trace_internal_read on public.ols_orders_cache;
create policy trace_internal_read on public.ols_orders_cache
for select to authenticated using (public.is_internal_staff(auth.uid()));

drop policy if exists ols_auth_read on public.ols_products_cache;
drop policy if exists trace_internal_read on public.ols_products_cache;
create policy trace_internal_read on public.ols_products_cache
for select to authenticated using (public.is_internal_staff(auth.uid()));

drop policy if exists ols_auth_read on public.ols_production_batches;
drop policy if exists trace_internal_read on public.ols_production_batches;
create policy trace_internal_read on public.ols_production_batches
for select to authenticated using (public.is_internal_staff(auth.uid()));

drop policy if exists ols_auth_read on public.ols_production_labels;
drop policy if exists trace_internal_read on public.ols_production_labels;
create policy trace_internal_read on public.ols_production_labels
for select to authenticated using (public.is_internal_staff(auth.uid()));

drop policy if exists "Allow authenticated full access on dispatches" on public.dispatches;
drop policy if exists "Users can view their dispatches" on public.dispatches;
drop policy if exists "Admin All Access Dispatches" on public.dispatches;
drop policy if exists "Internal staff read legacy dispatches" on public.dispatches;
drop policy if exists "Dispatch authority insert legacy dispatches" on public.dispatches;
drop policy if exists "Dispatch authority update legacy dispatches" on public.dispatches;
drop policy if exists "Dispatch authority delete legacy dispatches" on public.dispatches;

create policy "Internal staff read legacy dispatches"
on public.dispatches for select to authenticated
using (public.is_internal_staff(auth.uid()));

create policy "Dispatch authority insert legacy dispatches"
on public.dispatches for insert to authenticated
with check (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

create policy "Dispatch authority update legacy dispatches"
on public.dispatches for update to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
)
with check (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

create policy "Dispatch authority delete legacy dispatches"
on public.dispatches for delete to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in (
    'DISPATCH_MANAGER','DISPATCH_HEAD','DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'
  )
);

revoke select on table
  public.products,
  public.product_pricing_rules,
  public.product_moq_rules,
  public.dispatches,
  public.ols_orders_cache,
  public.ols_products_cache,
  public.ols_production_batches,
  public.ols_production_labels
from anon;

commit;
