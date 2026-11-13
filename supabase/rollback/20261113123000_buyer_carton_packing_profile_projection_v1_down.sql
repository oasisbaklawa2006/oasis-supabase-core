-- Rollback for 20261113123000_buyer_carton_packing_profile_projection_v1.sql.
-- Safe only after 20261101100000 (carton enforcement) is rolled back: its evaluator reads both tables. The Buyer app falls back to "no carton view" when the RPCs are absent.
-- Both governance tables are DROPPED, including retired rows that carry approval evidence. A verified backup of BOTH tables is
-- required whenever EITHER table contains any row (not only approved rows); the guard below refuses to proceed otherwise.
do $$
begin
  if to_regclass('public.carton_enforcement_settings') is not null then
    raise exception 'ROLLBACK_REFUSED: roll back 20261101100000_buyer_carton_full_checkout_enforcement_v1 first (its evaluator reads these tables)';
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
