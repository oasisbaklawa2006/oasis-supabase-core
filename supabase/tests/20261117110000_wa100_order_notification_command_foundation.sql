-- WA-100 #540: staged Core outbound command boundary; never live sends.
begin;
select plan(16);

select has_table('public','wa100_utility_template_registry');
select has_table('public','wa100_order_notification_commands');
select has_table('public','wa100_order_notification_command_events');
select has_function('public','enqueue_wa100_order_notification_v1',
  array['uuid','text','uuid','text','text','integer']);

select ok(has_function_privilege('service_role',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'service_role can invoke protected enqueue');
select ok(not has_function_privilege('authenticated',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'ordinary authenticated users cannot enqueue');
select ok(not has_function_privilege('anon',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'anonymous users cannot enqueue');
select ok(not has_table_privilege('authenticated',
  'public.wa100_order_notification_commands','INSERT'),
  'ordinary users cannot forge outbound commands');
select ok(not has_table_privilege('authenticated',
  'public.wa100_order_notification_commands','SELECT'),
  'ordinary users cannot read confidential recipient rows');
select ok(not has_table_privilege('service_role',
  'public.wa100_order_notification_commands','UPDATE'),
  'application service_role cannot rewrite immutable command status');

select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_order_notification_commands'::regclass
    and c.conname='wa100_order_event_revision_uniq'
), 'one durable command per order event and revision');

select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_utility_template_registry'::regclass
    and c.conname='wa100_template_approval_guard'
), 'enabled template metadata requires approval evidence');
select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_order_notification_commands'::regclass
    and c.contype='c'
    and pg_get_constraintdef(c.oid) like '%NOT_SENT_RELEASE_GATED%'
), 'command status cannot claim sent/delivered in this release');

select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($wa100_untrusted$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'SO_CREATED','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_untrusted$, '42501');

select set_config('request.jwt.claims','{"role":"service_role"}',true);
select throws_ok($wa100_bad_event$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'INVALID','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_bad_event$, '22023');
select throws_ok($wa100_no_order$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'SO_CREATED','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_no_order$, '23503');

select * from finish();
rollback;
