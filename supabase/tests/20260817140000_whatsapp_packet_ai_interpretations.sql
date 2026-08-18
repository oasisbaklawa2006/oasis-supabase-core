-- Contract assertions for automatic B2B WhatsApp packet AI persistence.
begin;

select plan(1);

do $$
begin
  if to_regclass('public.whatsapp_packet_ai_interpretations') is null then
    raise exception 'whatsapp_packet_ai_interpretations is missing';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations' and c.relrowsecurity
  ) then
    raise exception 'whatsapp_packet_ai_interpretations must have RLS enabled';
  end if;
  if has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','INSERT')
     or has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','UPDATE')
     or has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','DELETE') then
    raise exception 'authenticated users must not mutate packet AI interpretations';
  end if;
  if not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','SELECT') then
    raise exception 'authenticated inbox readers need SELECT grant for RLS evaluation';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.whatsapp_packet_ai_interpretations'::regclass
      and tgname='whatsapp_packet_ai_interpretations_append_only'
      and not tgisinternal
  ) then
    raise exception 'append-only trigger missing for packet AI interpretations';
  end if;
end $$;

select ok(true, 'WhatsApp packet AI persistence remains append-only and RLS governed');
select * from finish();
rollback;
