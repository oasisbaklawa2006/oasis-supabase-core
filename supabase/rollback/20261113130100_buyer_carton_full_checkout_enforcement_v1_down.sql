-- Rollback guard for default-OFF carton enforcement.
-- Refuse removal while enforcement is active or immutable exceptions exist.
-- Lock both governance tables before checking, so concurrent writers cannot
-- insert audit evidence or enable enforcement between the guard and DROPs.
-- On error, the single transaction rolls back all changes.
begin;
set local lock_timeout = '10s';
lock table public.carton_enforcement_settings, public.carton_enforcement_exceptions in access exclusive mode;
do $$
begin
  if exists (select 1 from public.carton_enforcement_settings where enabled) then
    raise exception 'ROLLBACK_REFUSED: carton enforcement is enabled; disable it through an approved release before rollback';
  end if;
  if to_regclass('public.carton_enforcement_exceptions') is not null and exists (select 1 from public.carton_enforcement_exceptions) then
    raise exception 'ROLLBACK_REFUSED: carton_enforcement_exceptions holds immutable audit records; export and verify a backup, then truncate deliberately before rolling back';
  end if;
end $$;
drop trigger if exists trg_orders_carton_dispatch_gate on public.orders;
drop function if exists public.enforce_order_carton_dispatch_gate_v1();
drop trigger if exists trg_order_items_carton_enforcement on public.order_items;
drop function if exists public.grant_carton_enforcement_exception_v1(text, uuid, text);
drop function if exists public.enforce_order_carton_completeness_v1();
drop function if exists public.evaluate_order_carton_completeness_v1(uuid);
drop table if exists public.carton_enforcement_exceptions;
drop table if exists public.carton_enforcement_settings;
drop function if exists public.protect_carton_enforcement_audit_v1();
commit;
