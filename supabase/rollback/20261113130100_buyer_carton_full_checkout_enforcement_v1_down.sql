-- Rollback guard for default-OFF carton enforcement.
-- Refuse removal while enforcement is active or immutable exceptions exist.
-- Lock both governance tables before checking, so concurrent writers cannot
-- insert audit evidence or enable enforcement between the guard and DROPs.
-- On error, the single transaction rolls back all changes.
begin;
set local lock_timeout = '10s';
lock table public.carton_enforcement_settings, public.carton_enforcement_exceptions, public.carton_enforcement_verifications in access exclusive mode;
do $$
begin
  if exists (select 1 from public.carton_enforcement_settings where enabled) then
    raise exception 'ROLLBACK_REFUSED: carton enforcement is enabled; disable it through an approved release before rollback';
  end if;
  if to_regclass('public.carton_enforcement_exceptions') is not null and exists (select 1 from public.carton_enforcement_exceptions) then
    raise exception 'ROLLBACK_REFUSED: carton_enforcement_exceptions holds immutable audit records; export and verify a backup, then truncate deliberately before rolling back';
  end if;
  if exists (select 1 from public.carton_enforcement_verifications) then
    raise exception 'ROLLBACK_REFUSED: carton_enforcement_verifications holds accepted order snapshots; export and reconcile evidence before rollback';
  end if;
end $$;
drop trigger if exists trg_carton_line_global_stmt_lock on public.order_items;
drop trigger if exists trg_carton_order_global_stmt_lock on public.orders;
drop trigger if exists trg_carton_profile_global_stmt_lock on public.product_packing_profiles;
drop trigger if exists trg_carton_config_global_stmt_lock on public.carton_configurations;
drop function if exists public.acquire_carton_global_mutation_lock_v1();
drop trigger if exists trg_orders_carton_created_at_guard on public.orders;
drop function if exists public.guard_carton_order_created_at_v1();
drop trigger if exists trg_orders_carton_new_order_enforcement on public.orders;
drop trigger if exists trg_orders_carton_revision_guard on public.orders;
drop trigger if exists trg_a_order_items_carton_revision on public.order_items;
drop trigger if exists trg_order_items_carton_revision on public.order_items;
drop trigger if exists trg_orders_carton_dispatch_gate on public.orders;
drop function if exists public.enforce_new_order_carton_v1();
drop function if exists public.enforce_order_carton_dispatch_gate_v1();
drop trigger if exists trg_order_items_carton_enforcement on public.order_items;
drop function if exists public.grant_carton_enforcement_exception_v1(text, uuid, text);
drop function if exists public.enforce_order_carton_completeness_v1();
drop function if exists public.assert_carton_order_ready_v1(uuid, text);
drop function if exists public.touch_carton_line_revision_v1();
drop function if exists public.guard_carton_line_revision_v1();
drop function if exists public.evaluate_order_carton_completeness_v1(uuid);
drop function if exists public.evaluate_order_carton_candidate_v1(uuid, boolean);
drop table if exists public.carton_enforcement_verifications;
alter table public.orders drop column if exists carton_line_revision;
drop table if exists public.carton_enforcement_exceptions;
drop table if exists public.carton_enforcement_settings;
drop function if exists public.protect_carton_enforcement_audit_v1();
commit;
