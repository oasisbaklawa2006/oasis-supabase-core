-- Contract for 20261121220000_torch_bearer_readonly_debugger.sql
begin;
set transaction read only;
select plan(28);

select ok(
  exists (
    select 1 from pg_roles
    where rolname = 'torch_bearer_reader' and rolcanlogin is false
  ),
  'torch_bearer_reader exists and cannot log in'
);

select ok(
  exists (
    select 1
    from pg_roles r,
    lateral unnest(coalesce(r.rolconfig, array[]::text[])) cfg
    where r.rolname = 'torch_bearer_reader'
      and cfg = 'default_transaction_read_only=on'
  ),
  'torch_bearer_reader defaults to read-only transactions'
);

select ok(
  has_schema_privilege('torch_bearer_reader', 'torch_bearer', 'USAGE')
  and not has_schema_privilege('torch_bearer_reader', 'torch_bearer', 'CREATE'),
  'reader has schema USAGE but not CREATE'
);

select ok(
  (
    select count(*) = 1 and bool_and(a.privilege_type = 'USAGE')
    from pg_namespace n
    cross join lateral aclexplode(
      coalesce(n.nspacl, acldefault('n', n.nspowner))
    ) a
    join pg_roles r on r.oid = a.grantee
    where n.nspname = 'torch_bearer'
      and r.rolname = 'torch_bearer_reader'
  ),
  'reader has only a direct USAGE grant on the schema'
);

select ok(
  (
    select count(*) = 4
       and count(*) filter (where c.relname in (
         'wa_outbox_summary_v1',
         'config_policy_summary_v1',
         'migration_ledger_summary_v1',
         'device_sync_summary_v1'
       )) = 4
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'torch_bearer' and c.relkind = 'v'
  ),
  'torch_bearer contains exactly the four aggregate views'
);

select ok(
  (
    select count(*) = 4
       and bool_and(c.reloptions @> array['security_invoker=false'])
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'torch_bearer' and c.relkind = 'v'
  ),
  'all four views run with security_invoker=false'
);

select ok(
  (
    select count(*) = 4
       and count(*) filter (where a.privilege_type = 'SELECT') = 4
       and count(distinct c.relname) = 4
       and bool_and(c.relname in (
         'wa_outbox_summary_v1',
         'config_policy_summary_v1',
         'migration_ledger_summary_v1',
         'device_sync_summary_v1'
       ))
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(
      coalesce(c.relacl, acldefault('r', c.relowner))
    ) a
    join pg_roles r on r.oid = a.grantee
    where n.nspname = 'torch_bearer'
      and c.relkind = 'v'
      and r.rolname = 'torch_bearer_reader'
  ),
  'reader has SELECT on only the four aggregate views'
);

select ok(
  not exists (
    select 1
    from pg_namespace n
    cross join lateral aclexplode(
      coalesce(n.nspacl, acldefault('n', n.nspowner))
    ) a
    where n.nspname = 'torch_bearer' and a.grantee = 0
  ),
  'PUBLIC has no privilege on the torch_bearer schema'
);

select ok(
  not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(
      coalesce(c.relacl, acldefault('r', c.relowner))
    ) a
    where n.nspname = 'torch_bearer' and c.relkind = 'v' and a.grantee = 0
  ),
  'PUBLIC has no privilege on the four views'
);

select ok(
  not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(
      coalesce(c.relacl, acldefault('r', c.relowner))
    ) a
    join pg_roles r on r.oid = a.grantee
    where n.nspname = 'public'
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and r.rolname = 'torch_bearer_reader'
  ),
  'reader has no direct grants on public application relations'
);

select ok(
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) a
    join pg_roles r on r.oid = a.grantee
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and r.rolname = 'torch_bearer_reader'
  ),
  'reader has no direct EXECUTE grants on public routines'
);

select ok(
  (select array_agg(a.attname::text order by a.attnum)
     from pg_attribute a
    where a.attrelid = 'torch_bearer.wa_outbox_summary_v1'::regclass
      and a.attnum > 0 and not a.attisdropped)
    = array['source', 'dimension', 'key', 'row_count', 'oldest_at', 'newest_at']
  and (select array_agg(a.attname::text order by a.attnum)
         from pg_attribute a
        where a.attrelid = 'torch_bearer.config_policy_summary_v1'::regclass
          and a.attnum > 0 and not a.attisdropped)
    = array['source_key', 'table_state', 'state', 'row_count', 'enabled_count',
            'disabled_count', 'unknown_count']
  and (select array_agg(a.attname::text order by a.attnum)
         from pg_attribute a
        where a.attrelid = 'torch_bearer.migration_ledger_summary_v1'::regclass
          and a.attnum > 0 and not a.attisdropped)
    = array['ledger_state', 'applied_count', 'earliest_version',
            'latest_version', 'versions']
  and (select array_agg(a.attname::text order by a.attnum)
         from pg_attribute a
        where a.attrelid = 'torch_bearer.device_sync_summary_v1'::regclass
          and a.attnum > 0 and not a.attisdropped)
    = array['source_key', 'table_state', 'device_count', 'active_count',
            'last_seen_at', 'last_seen_state', 'last_successful_sync_at',
            'last_sync_state'],
  'views expose only aggregate fields, states, and migration versions'
);

select ok(
  not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
    where n.nspname = 'torch_bearer'
      and c.relkind = 'v'
      and a.attnum > 0 and not a.attisdropped
      and a.attname ~* '(body|phone|recipient|payload|token|secret|api_key|credential|provider|evidence|detail|statement|dsn|device_id|label)'
  ),
  'no view output column exposes bodies, identifiers, payloads, secrets, or credentials'
);

select ok(
  not exists (
    select 1 from torch_bearer.wa_outbox_summary_v1
    where key !~ '^[A-Z][A-Z0-9_]{1,47}$'
       or key ~ '[0-9]{5,}'
  ),
  'outbox keys contain only sanitized tokens without long numeric identifiers'
);

select is(
  coalesce((
    select row_count from torch_bearer.wa_outbox_summary_v1
    where source = 'operator_reply_outbox'
      and dimension = 'status' and key = 'ACCEPTED'
  ), 0::bigint),
  (select count(*) from public.whatsapp_operator_reply_outbox where status = 'ACCEPTED'),
  'accepted outbox count matches the source'
);

select is(
  coalesce((
    select row_count from torch_bearer.wa_outbox_summary_v1
    where source = 'operator_reply_outbox'
      and dimension = 'status' and key = 'FAILED_FINAL'
  ), 0::bigint),
  (select count(*) from public.whatsapp_operator_reply_outbox where status = 'FAILED_FINAL'),
  'failed-final outbox count matches the source'
);

select is(
  coalesce((
    select row_count from torch_bearer.wa_outbox_summary_v1
    where source = 'operator_reply_outbox'
      and dimension = 'status' and key = 'QUARANTINED'
  ), 0::bigint),
  (select count(*) from public.whatsapp_operator_reply_outbox where status = 'QUARANTINED'),
  'quarantined outbox count matches the source'
);

select is(
  coalesce((
    select row_count from torch_bearer.wa_outbox_summary_v1
    where source = 'operator_reply_outbox'
      and dimension = 'callback' and key = 'ACCEPTED'
  ), 0::bigint),
  (select count(*) from public.whatsapp_operator_reply_outbox
    where accepted_at is not null),
  'accepted callback count matches the source'
);

select ok(
  exists (
    select 1
    from torch_bearer.config_policy_summary_v1 c
    where c.source_key = 'whatsapp_config'
      and (
        (to_regclass('public.whatsapp_config') is null
          and c.table_state = 'ABSENT' and c.state = 'ABSENT'
          and c.row_count is null)
        or
        (to_regclass('public.whatsapp_config') is not null
          and c.table_state = 'PRESENT' and c.row_count is not null
          and ((c.state = 'ZERO_ROW') = (c.row_count = 0)))
      )
  ),
  'config summary distinguishes an absent source from a present zero-row source'
);

select ok(
  exists (
    select 1 from torch_bearer.config_policy_summary_v1
    where source_key = 'whatsapp_config'
      and table_state = 'PRESENT' and state = 'ZERO_ROW' and row_count = 0
  ),
  'empty WhatsApp config is reported as ZERO_ROW, not ABSENT'
);

select ok(
  exists (
    select 1 from torch_bearer.config_policy_summary_v1
    where source_key = 'order_production_evidence_policy'
      and table_state = 'PRESENT' and state = 'DISABLED'
      and row_count > 0 and enabled_count = 0 and disabled_count = row_count
  ),
  'disabled production evidence policy is reported as DISABLED'
);

select ok(
  not exists (
    select 1
    from torch_bearer.device_sync_summary_v1 d
    where (not exists (
             select 1 from information_schema.columns c
             where c.table_schema = 'public'
               and c.table_name = d.source_key
               and c.column_name = 'last_successful_sync_at'
               and c.data_type = 'timestamp with time zone'
           )
           and (d.last_sync_state <> 'UNKNOWN'
                or d.last_successful_sync_at is not null))
       or d.last_sync_state not in ('KNOWN', 'UNKNOWN')
  )
  and exists (
    select 1 from torch_bearer.device_sync_summary_v1
    where last_sync_state = 'UNKNOWN' and last_successful_sync_at is null
  ),
  'device sync remains UNKNOWN when no successful-sync source exists'
);

select diag(
  'Phase 3 hardening note: PUBLIC-executable routines in public: '
  || coalesce((
    select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and (
        p.proacl is null
        or exists (
          select 1
          from aclexplode(p.proacl) a
          where a.grantee = 0 and a.privilege_type = 'EXECUTE'
        )
      )
  ), 'none')
);

set local default_transaction_read_only = on;
set local role torch_bearer_reader;

select is(
  current_setting('default_transaction_read_only'),
  'on',
  'reader session is read-only by default'
);

select lives_ok(
  $$select count(*) from torch_bearer.wa_outbox_summary_v1$$,
  'reader can read the outbox summary'
);

select lives_ok(
  $$select count(*) from torch_bearer.config_policy_summary_v1$$,
  'reader can read the config summary'
);

select lives_ok(
  $$select count(*) from torch_bearer.migration_ledger_summary_v1$$,
  'reader can read the migration ledger summary'
);

select lives_ok(
  $$select count(*) from torch_bearer.device_sync_summary_v1$$,
  'reader can read the device sync summary'
);

select throws_ok(
  $$create temporary table torch_bearer_readonly_probe (id integer)$$,
  '25006',
  null,
  'writes fail in a read-only transaction'
);

reset role;
select * from finish();
rollback;
