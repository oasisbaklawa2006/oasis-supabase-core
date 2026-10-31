-- Rollback for 20261101090000_buyer_carton_packing_profile_projection_v1.sql.
-- Safe because nothing else depends on these objects (the Buyer app falls back to "no carton view" when the RPCs are absent).
-- Back up the two governance tables first if any approved rows exist: this drops their data.
drop function if exists public.buyer_packing_profiles_v1();
drop function if exists public.buyer_carton_configurations_v1();
drop table if exists public.product_packing_profiles;
drop table if exists public.carton_configurations;
drop function if exists public.protect_approved_carton_packing_rows_v1();
drop function if exists public.validate_carton_configuration_groups_v1();
