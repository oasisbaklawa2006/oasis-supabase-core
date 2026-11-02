-- Rollback for 20261102100000_buyer_delivery_address_and_saved_transporter_authority_v1.sql.
-- Buyer builds that call these RPCs must be rolled back first (address/transporter screens would fail closed).
-- The transporter table is only dropped while empty so saved buyer data is never destroyed silently.
drop function if exists public.customer_upsert_delivery_address_v1(uuid, text, text, text, text, text, text, text, boolean);
drop function if exists public.customer_delete_delivery_address_v1(uuid);
drop function if exists public.customer_saved_transporters_v1();
drop function if exists public.customer_upsert_saved_transporter_v1(uuid, text, text, boolean, boolean);
drop function if exists public.customer_delete_saved_transporter_v1(uuid);
do $$
begin
  if to_regclass('public.customer_saved_transporters') is not null then
    if exists (select 1 from public.customer_saved_transporters) then
      raise exception 'ROLLBACK_REFUSED: public.customer_saved_transporters holds buyer data; export it before dropping the table';
    end if;
    drop table public.customer_saved_transporters;
  end if;
end $$;
