-- Rollback for 20261113130000_buyer_carton_packing_profile_projection_v1.sql.
-- Safe only after 20261113130100 (carton enforcement) is rolled back: its evaluator reads both tables. The Buyer app falls back to "no carton view" when the RPCs are absent.
-- Both governance tables are DROPPED, including retired rows that carry approval evidence. A verified backup of BOTH tables is
-- required whenever EITHER table contains any row (not only approved rows); the guard below refuses to proceed otherwise.
-- All reads, guards and DDL belong to ONE transaction. Take ACCESS EXCLUSIVE
-- locks BEFORE the emptiness check, so no writer can insert approval/evidence
-- rows between the guard and the table drops. A lock failure aborts safely.
begin;
set local lock_timeout = '10s';
lock table public.carton_configurations, public.product_packing_profiles in access exclusive mode;
do $$
begin
  if to_regclass('public.carton_enforcement_settings') is not null then
    raise exception 'ROLLBACK_REFUSED: roll back 20261113130100_buyer_carton_full_checkout_enforcement_v1 first (its evaluator reads these tables)';
  end if;
  if (to_regclass('public.carton_configurations') is not null and exists (select 1 from public.carton_configurations))
     or (to_regclass('public.product_packing_profiles') is not null and exists (select 1 from public.product_packing_profiles)) then
    raise exception 'ROLLBACK_REFUSED: carton_configurations / product_packing_profiles hold governance rows (including retired approval evidence); export both tables, verify the backup, and only then truncate them deliberately before rolling back';
  end if;
end $$;
drop function if exists public.buyer_packing_profiles_v1();
drop function if exists public.buyer_carton_configurations_v1();
drop table if exists public.product_packing_profiles;
drop table if exists public.carton_configurations;
drop function if exists public.protect_approved_carton_packing_rows_v1();
drop function if exists public.validate_carton_configuration_groups_v1();
drop function if exists public.validate_profile_config_refs_v1();
commit;
