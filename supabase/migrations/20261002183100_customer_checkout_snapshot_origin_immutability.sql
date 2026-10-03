-- Target 3 hardening: freeze both CUSTOMER_APP provenance and its financial snapshot.
-- release-dispatch-noop: comment-only touch to re-enter the protected production migration release after PR #391 lineage reconciliation; executable SQL unchanged.
begin;

create or replace function public.prevent_customer_checkout_snapshot_mutation_v1()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if (old.order_origin = 'CUSTOMER_APP' or new.order_origin = 'CUSTOMER_APP')
     and (
       new.checkout_snapshot is distinct from old.checkout_snapshot
       or new.order_origin is distinct from old.order_origin
     ) then
    raise exception 'CUSTOMER_CHECKOUT_SNAPSHOT_IMMUTABLE'
      using errcode = '55000',
            detail = 'CUSTOMER_APP provenance and commercial truth are frozen when checkout is submitted';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customer_checkout_snapshot_immutable on public.orders;
create trigger trg_customer_checkout_snapshot_immutable
before update of checkout_snapshot, order_origin
on public.orders
for each row
execute function public.prevent_customer_checkout_snapshot_mutation_v1();

commit;
