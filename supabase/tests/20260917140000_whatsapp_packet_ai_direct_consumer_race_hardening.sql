-- Superseded by Gate 6 (20260918200000): direct packet claim is retired.
-- Retained file name preserves migration traceability while enforcing final authority.
begin;
select plan(2);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86511000-0000-0000-0000-000000000001', '919651100001', 'Direct path retired contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86511000-0000-0000-0000-000000000011', '86511000-0000-0000-0000-000000000001',
  'inbound', 'text', 'direct path retired', 'click2api', 'direct-retired-a', 'received',
  statement_timestamp(), statement_timestamp()
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86511000-0000-0000-0000-000000000001',
    array['86511000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'fixture packet exists for direct-path retirement check'
);

select is(
  (select public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from public.whatsapp_messages where id = '86511000-0000-0000-0000-000000000011'),
    120
  )),
  null::public.whatsapp_packet_ai_dispatch_jobs,
  'Gate 6 retires legacy direct packet-scoped dispatch claim'
);

select * from finish();
rollback;
