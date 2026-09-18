-- Contract for 20260919150000_whatsapp_gate6_legacy_direct_ai_removal.sql
begin;
select plan(6);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86600000-0000-0000-0000-000000000001', '919660000001', 'Gate6 contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86600000-0000-0000-0000-000000000011', '86600000-0000-0000-0000-000000000001',
  'inbound', 'text', 'Gate 6 packet', 'click2api', 'gate6-inbound-a', 'received',
  statement_timestamp(), statement_timestamp()
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86600000-0000-0000-0000-000000000001',
    array['86600000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'gate6 fixture stitches one inbound packet'
);

select is(
  (select public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from public.whatsapp_messages where id = '86600000-0000-0000-0000-000000000011'),
    120
  )),
  null::public.whatsapp_packet_ai_dispatch_jobs,
  'legacy direct packet claim is retired and returns null'
);

select ok(
  exists(
    select 1
    from public.whatsapp_packet_ai_dispatch_jobs j
    join public.whatsapp_messages m on m.packet_id = j.packet_id
    where m.id = '86600000-0000-0000-0000-000000000011'
      and j.state = 'QUEUED'
  ),
  'canonical dispatch outbox row remains queued for consumer authority'
);

select ok(
  (select public.claim_whatsapp_packet_ai_dispatch_job(120)).id is not null,
  'canonical consumer claim path remains available'
);

select ok(
  exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'claim_whatsapp_packet_ai_dispatch_job'
  ),
  'single canonical inbound dispatch claim function remains service-only'
);

select ok(
  exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'claim_whatsapp_operator_reply'
  ),
  'single canonical outbound execution claim function remains present'
);

select * from finish();
rollback;
