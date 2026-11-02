-- Rollback for 20261102100000_buyer_delivery_address_and_saved_transporter_authority_v1.sql.
-- Buyer builds that call these RPCs must be rolled back first (address/transporter screens would fail closed).
-- ONE transaction, safety check FIRST: if the transporter table holds buyer data the whole rollback is refused and NOTHING is dropped
-- (no RPCs are removed while data remains). If a client runs this file without ON_ERROR_STOP, the aborted transaction still skips every
-- later statement. The table is locked before the empty check so a concurrent writer cannot commit between the check and the drop.
begin;
do $$
begin
  if to_regclass('public.customer_saved_transporters') is not null then
    lock table public.customer_saved_transporters in access exclusive mode;
    if exists (select 1 from public.customer_saved_transporters) then
      raise exception 'ROLLBACK_REFUSED: public.customer_saved_transporters holds buyer data; export it before dropping the table';
    end if;
  end if;
end $$;
drop function if exists public.customer_upsert_delivery_address_v1(uuid, text, text, text, text, text, text, text, boolean);
drop function if exists public.customer_delete_delivery_address_v1(uuid);
drop function if exists public.customer_saved_transporters_v1();
drop function if exists public.customer_upsert_saved_transporter_v1(uuid, text, text, boolean, boolean);
drop function if exists public.customer_delete_saved_transporter_v1(uuid);
drop table if exists public.customer_saved_transporters;
commit;
