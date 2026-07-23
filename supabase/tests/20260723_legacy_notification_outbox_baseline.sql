-- Contract test for migration 20260723152800_legacy_notification_outbox_baseline
begin;

select plan(8);

select has_table('public', 'notification_events', 'notification_events baseline exists');
select has_table('public', 'notification_outbox', 'notification_outbox baseline exists');

select has_column('public', 'notification_events', 'event_key', 'notification_events.event_key exists');
select has_column('public', 'notification_events', 'template_body', 'notification_events.template_body exists');
select has_column('public', 'notification_outbox', 'message_body', 'notification_outbox.message_body exists');
select has_column('public', 'notification_outbox', 'status', 'notification_outbox.status exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.notification_events'::regclass),
  'notification_events has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.notification_outbox'::regclass),
  'notification_outbox has RLS enabled'
);

select * from finish();
rollback;
