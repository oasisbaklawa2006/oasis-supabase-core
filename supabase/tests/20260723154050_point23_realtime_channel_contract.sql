-- Contract and behavioral coverage for Point 23 shared realtime-channel standards.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723161000.
begin;

select plan(24);

select has_table(
  'public',
  'realtime_subscription_contracts',
  'realtime_subscription_contracts allow-list authority exists'
);

select has_view(
  'public',
  'realtime_contract_health',
  'realtime_contract_health runtime verification view exists'
);

select columns_are(
  'public',
  'realtime_subscription_contracts',
  array[
    'id', 'schema_name', 'table_name', 'owning_application', 'consumer_applications',
    'enabled', 'row_filter_required', 'rls_required', 'event_types', 'notes',
    'created_at', 'updated_at'
  ],
  'realtime_subscription_contracts exposes the governed contract envelope'
);

select col_is_unique(
  'public',
  'realtime_subscription_contracts',
  array['schema_name', 'table_name'],
  'realtime contracts are unique per schema and table'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.realtime_subscription_contracts'::regclass),
  'realtime_subscription_contracts row level security is enabled'
);

select ok(
  exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'realtime_contract_health'
      and c.reloptions @> array['security_invoker=true']
  ),
  'realtime_contract_health is security invoker'
);

select is(
  (select count(*)::bigint from public.realtime_subscription_contracts where enabled),
  3::bigint,
  'exactly three enabled realtime subscription contracts are authoritative'
);

select is(
  (select count(*)::bigint from public.realtime_contract_health where enabled and health_status = 'healthy'),
  3::bigint,
  'all enabled realtime contracts report healthy publication and RLS readiness'
);

select is(
  (
    select count(*)::bigint
    from pg_publication_tables p
    left join public.realtime_subscription_contracts c
      on c.schema_name = p.schemaname
     and c.table_name = p.tablename
     and c.enabled
    where p.pubname = 'supabase_realtime'
      and p.schemaname = 'public'
      and c.id is null
  ),
  0::bigint,
  'supabase_realtime public tables are allow-listed by enabled contracts only'
);

select is(
  (
    select count(*)::bigint
    from public.realtime_subscription_contracts c
    where c.enabled
      and c.schema_name = 'public'
      and not exists (
        select 1
        from pg_publication_tables p
        where p.pubname = 'supabase_realtime'
          and p.schemaname = c.schema_name
          and p.tablename = c.table_name
      )
  ),
  0::bigint,
  'every enabled contract table is published to supabase_realtime'
);

select ok(
  not exists(
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
      and puballtables
  ),
  'supabase_realtime does not use unsafe all-tables publication'
);

select ok(
  (
    select bool_and(cls.relrowsecurity)
    from public.realtime_subscription_contracts c
    join pg_namespace ns on ns.nspname = c.schema_name
    join pg_class cls on cls.relnamespace = ns.oid and cls.relname = c.table_name and cls.relkind = 'r'
    where c.enabled
  ),
  'every enabled realtime contract table has RLS enabled'
);

select ok(
  (
    select bool_and(
      exists (
        select 1
        from pg_policies pol
        where pol.schemaname = c.schema_name
          and pol.tablename = c.table_name
          and pol.cmd in ('SELECT', 'ALL')
          and pol.qual like '%is_team_member%'
      )
    )
    from public.realtime_subscription_contracts c
    where c.enabled
  ),
  'enabled realtime tables use team-member read policies for fail-closed authorization'
);

select ok(
  (
    select bool_and(row_filter_required and rls_required)
    from public.realtime_subscription_contracts
    where enabled
  ),
  'enabled realtime contracts require row filters and RLS'
);

select ok(
  (
    select bool_and(
      event_types <@ array['INSERT', 'UPDATE', 'DELETE']::text[]
      and not ('DELETE' = any(event_types))
    )
    from public.realtime_subscription_contracts
    where enabled
  ),
  'enabled realtime contracts publish INSERT/UPDATE refresh events only'
);

select ok(
  (
    select bool_and(
      owning_application = 'Central'
      and consumer_applications @> array['Central', 'AI Studio']::text[]
    )
    from public.realtime_subscription_contracts
    where enabled
  ),
  'enabled realtime contracts name Central ownership and approved consumer apps'
);

select ok(
  (
    select bool_and(table_name = any(array[
      'whatsapp_inbound_messages',
      'whatsapp_operator_decisions',
      'whatsapp_sales_order_drafts'
    ]::text[]))
    from public.realtime_subscription_contracts
    where enabled and schema_name = 'public'
  ),
  'enabled realtime surface is limited to governed WhatsApp operator inbox tables'
);

insert into public.users (id, role) values
  ('a0230000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('a0230000-0000-0000-0000-000000000002', 'B2B_BUYER'),
  ('a0230000-0000-0000-0000-000000000003', 'ADMIN')
on conflict (id) do update set role = excluded.role;

insert into public.user_role_map (user_id, role_id)
select 'a0230000-0000-0000-0000-000000000003', id
from public.roles
where role_key = 'admin'
on conflict (user_id, role_id) do nothing;

reset role;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000002';
set local role authenticated;

select is_empty(
  $$select 1 from public.realtime_subscription_contracts$$,
  'non-internal staff cannot read realtime subscription contracts'
);

set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000001';

select isnt_empty(
  $$select 1 from public.realtime_subscription_contracts where enabled$$,
  'internal staff can read enabled realtime subscription contracts'
);

select isnt_empty(
  $$select 1 from public.realtime_contract_health where enabled$$,
  'internal staff can read realtime contract health diagnostics'
);

set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000002';

select is_empty(
  $$select 1 from public.whatsapp_inbound_messages where provider_message_id = 'point23-rls-probe'$$,
  'non-team authenticated users cannot subscribe-read whatsapp inbound messages'
);

reset role;
set local role service_role;

insert into public.whatsapp_inbound_messages (
  provider_message_id, sender_phone, sender_name, message_body
) values (
  'point23-rls-probe', '+919999999999', 'Point23 Probe', 'pgTAP realtime authorization probe'
);

reset role;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000003';
set local role authenticated;

select isnt_empty(
  $$select 1 from public.whatsapp_inbound_messages where provider_message_id = 'point23-rls-probe'$$,
  'team members can read governed whatsapp inbound messages for postgres_changes refresh'
);

set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000001';

select throws_like(
  $$insert into public.realtime_subscription_contracts (
    schema_name, table_name, owning_application, enabled
  ) values (
    'public', 'orders', 'Central', true
  )$$,
  '%row-level security%',
  'non-admin staff cannot expand realtime publication authority'
);

set local request.jwt.claim.sub = 'a0230000-0000-0000-0000-000000000002';

select throws_like(
  $$insert into public.whatsapp_inbound_messages (
    provider_message_id, sender_phone, message_body
  ) values (
    'point23-buyer-write', '+919999999998', 'buyer write probe'
  )$$,
  '%row-level security%',
  'non-team users cannot write whatsapp inbound messages through realtime-adjacent tables'
);

select * from finish();
rollback;
