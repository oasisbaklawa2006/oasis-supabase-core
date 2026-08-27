-- Stage 1 media ingress certification: prove captured media != terminal interpretation failure
-- when media is pending worker/download processing.
begin;
select plan(18);

-- TEST 1: media pending at capture must not set FAILED_INTERPRETATION
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values (
  'e1000000-0000-0000-0000-000000000001',
  'wa-s1-pdf-pending',
  '919911111111',
  '[unreadable document attachment]',
  'document',
  statement_timestamp(),
  '{"media_url":"https://click2api.in/media/pdf-po"}'::jsonb
);

select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000001',
    null,
    'wa-s1-pdf-pending',
    null,
    1,
    false,
    '{"ingress":"cert","fail_open_media_review":true}'::jsonb
  )$$,
  'commercial PDF fragment capture succeeds with pending media'
);

select is(
  (select processing_state from public.whatsapp_commercial_evidence where provider_message_id='wa-s1-pdf-pending'),
  'PENDING',
  'pending media evidence is PENDING not UNREADABLE'
);
select is(
  (select state from public.whatsapp_potential_orders p
    join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id
   where e.provider_message_id='wa-s1-pdf-pending'),
  'UNASSIGNED',
  'pending media does not terminalize potential order as FAILED_INTERPRETATION'
);
select is(
  (select status from public.whatsapp_commercial_packets p
    join public.whatsapp_commercial_evidence e on e.packet_id=p.id
   where e.provider_message_id='wa-s1-pdf-pending'),
  'AWAITING_MEDIA',
  'packet awaits media while worker has not completed'
);

-- TEST 2: image + caption captures without premature failure
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000002',
  'wa-s1-img-caption',
  '919911111111',
  'Please send 12 boxes BAK-PIST-250',
  'image',
  statement_timestamp()
);

select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000002', null, 'wa-s1-img-caption', null, 1, false, '{}'::jsonb
  )$$,
  'image + caption fragment capture succeeds'
);
select is(
  (select processing_state from public.whatsapp_commercial_evidence where provider_message_id='wa-s1-img-caption'),
  'PENDING',
  'image + caption remains pending until media processing completes'
);

-- TEST 3: text then image stitches to same packet
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000003',
  'wa-s1-text-first',
  '919911111111',
  'send pistachio baklawa',
  'text',
  statement_timestamp()
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000003', null, 'wa-s1-text-first', null, 0, false, '{}'::jsonb
  )$$,
  'text-first fragment captured'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000004',
  'wa-s1-img-follow',
  '919911111111',
  '[unreadable image attachment]',
  'image',
  statement_timestamp() + interval '2 seconds'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000004', null, 'wa-s1-text-first', null, 1, false,
    '{"fail_open_media_review":true}'::jsonb
  )$$,
  'image follow-up stitches to conversation'
);
select is(
  (select count(distinct packet_id) from public.whatsapp_commercial_evidence
    where provider_message_id in ('wa-s1-text-first','wa-s1-img-follow')),
  1::bigint,
  'text then image share one packet'
);

-- TEST 4: multiple images same packet
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000005',
  'wa-s1-multi-1',
  '919922222222',
  '[unreadable image attachment]',
  'image',
  statement_timestamp()
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000005', null, 'wa-s1-multi-1', null, 1, false,
    '{"fail_open_media_review":true}'::jsonb
  )$$,
  'first multi-image fragment captured'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000006',
  'wa-s1-multi-2',
  '919922222222',
  '[unreadable image attachment]',
  'image',
  statement_timestamp() + interval '1 second'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000006', null, 'wa-s1-multi-1', null, 1, false,
    '{"fail_open_media_review":true}'::jsonb
  )$$,
  'second multi-image fragment captured'
);
select is(
  (select count(*) from public.whatsapp_commercial_evidence
    where provider_message_id in ('wa-s1-multi-1','wa-s1-multi-2')),
  2::bigint,
  'multiple images create distinct evidence rows'
);

-- TEST 5: inaccessible media completion fails closed without silent loss
select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1-pdf-pending','TIMED_OUT','attempt-provider-timeout','{"stage":"provider_download"}'::jsonb
  )$$,
  'inaccessible media records TIMED_OUT outcome'
);
select is(
  (select state from public.whatsapp_potential_orders p
    join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id
   where e.provider_message_id='wa-s1-pdf-pending'),
  'FAILED_INTERPRETATION',
  'only after explicit media failure does potential order become FAILED_INTERPRETATION'
);

-- TEST 6: corrupt / unsupported / failed states are actionable
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000007',
  'wa-s1-corrupt',
  '919933333333',
  '[unreadable image attachment]',
  'image',
  statement_timestamp()
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000007', null, 'wa-s1-corrupt', null, 1, true, '{}'::jsonb
  )$$,
  'explicit interpretation failure at capture still allowed for true unreadable bootstrap'
);
select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1-corrupt','CORRUPT','attempt-corrupt','{"reason":"bad bytes"}'::jsonb
  )$$,
  'corrupt media outcome persists'
);

-- TEST 7: duplicate webhook idempotent
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000001', null, 'wa-s1-pdf-pending', null, 1, false,
    '{"replay":true}'::jsonb
  )$$,
  'duplicate provider message replay is idempotent'
);
select is(
  (select count(*) from public.whatsapp_commercial_evidence where provider_message_id='wa-s1-pdf-pending'),
  1::bigint,
  'duplicate webhook creates no extra evidence'
);

-- TEST 8: bootstrap media success recovers FAILED_INTERPRETATION when fail_open flagged
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e1000000-0000-0000-0000-000000000008',
  'wa-s1-recover',
  '919944444444',
  '[unreadable image attachment]',
  'image',
  statement_timestamp()
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e1000000-0000-0000-0000-000000000008', null, 'wa-s1-recover', null, 1, true,
    '{"fail_open_media_review":true}'::jsonb
  )$$,
  'bootstrap media with fail_open flag captured'
);
select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1-recover','SUCCEEDED','packet-ai:recover','{"worker":"packet-ai"}'::jsonb
  )$$,
  'successful media processing after bootstrap failure recovers order'
);
select is(
  (select state from public.whatsapp_potential_orders p
    join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id
   where e.provider_message_id='wa-s1-recover'),
  'UNASSIGNED',
  'bootstrap media success restores UNASSIGNED queue'
);

select is(
  (select unaccounted_potential_orders from public.whatsapp_potential_order_reconciliation),
  0::bigint,
  'media ingress reconciliation remains zero-loss'
);

select * from finish();
rollback;
