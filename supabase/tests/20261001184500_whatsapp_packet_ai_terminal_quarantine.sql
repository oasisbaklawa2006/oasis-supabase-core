-- Contract coverage for 20261001184500_whatsapp_packet_ai_terminal_quarantine.sql
begin;
select plan(10);

select ok(
  position('QUARANTINED' in pg_get_constraintdef((
    select oid from pg_constraint
    where conrelid='public.whatsapp_packet_ai_dispatch_jobs'::regclass
      and conname='whatsapp_packet_ai_dispatch_jobs_state_check'
  ))) > 0,
  'dispatch state contract includes terminal quarantine'
);

select ok(
  position('INTERPRETATION_PACKET_TOO_LARGE' in upper(pg_get_functiondef(
    'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)'::regprocedure
  ))) > 0,
  'retry authority recognizes the confirmed deterministic oversized-packet error'
);

select ok(
  not has_function_privilege('authenticated',
    'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)','execute'),
  'authenticated clients cannot invoke worker retry authority'
);

select ok(
  has_function_privilege('service_role',
    'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)','execute'),
  'service worker retains retry authority'
);

insert into public.whatsapp_contacts(id,phone_number,customer_name) values
  ('87100000-0000-0000-0000-000000000001','919710000001','Quarantine cert contact');
insert into public.whatsapp_messages(
  id,contact_id,direction,message_type,content,provider,provider_message_id,status,message_timestamp,created_at
) values (
  '87100000-0000-0000-0000-000000000011','87100000-0000-0000-0000-000000000001',
  'inbound','text','oversized packet certification','click2api','quarantine-cert-a','received',
  '2026-10-01 10:00:00','2026-10-01 10:00:00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '87100000-0000-0000-0000-000000000001',
    array['87100000-0000-0000-0000-000000000011'::uuid],300)$$,
  'fixture creates durable packet dispatch job'
);

set local request.jwt.claim.role='service_role';
create temporary table quarantine_claim as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select isnt((select id from quarantine_claim),null::uuid,'worker claims fixture job');

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from quarantine_claim),
    (select lease_token from quarantine_claim),
    (select packet_revision from quarantine_claim),
    'INTERPRETATION_PACKET_TOO_LARGE',
    'cert deterministic error',
    false
  ),
  'deterministic failure is recorded under the active lease'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from quarantine_claim)),
  'QUARANTINED',
  'oversized packet revision becomes terminally quarantined'
);

select is(
  (select id from public.claim_whatsapp_packet_ai_dispatch_job(120)),
  null::uuid,
  'quarantined revision is not reclaimed in a retry loop'
);

select is(
  (select count(*)::integer from public.operational_events
   where entity_id=(select id from quarantine_claim)
     and event_type='whatsapp_packet_ai_quarantined'),
  1,
  'quarantine creates one operator-visible operational event'
);

select * from finish();
rollback;
