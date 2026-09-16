-- Contract for 20260916200000_oasis_drift_watch_ro_authority.sql
begin;
select plan(22);

select ok(
  exists (select 1 from pg_roles where rolname = 'oasis_drift_watch_ro'),
  'oasis_drift_watch_ro role exists'
);

select ok(
  (select rolsuper from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro is not superuser'
);

select ok(
  (select rolcreatedb from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro cannot create databases'
);

select ok(
  (select rolcreaterole from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro cannot create roles'
);

select ok(
  (select rolreplication from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro cannot replicate'
);

select ok(
  (select rolbypassrls from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro does not bypass RLS'
);

select ok(
  (select rolinherit from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro does not inherit parent-role privileges'
);

select ok(
  (select rolcanlogin from pg_roles where rolname = 'oasis_drift_watch_ro') is false,
  'oasis_drift_watch_ro remains NOLOGIN until owner activation'
);

select ok(
  ',default_transaction_read_only=on,' like
    '%,' || coalesce((select array_to_string(rolconfig, ',') from pg_roles where rolname = 'oasis_drift_watch_ro'), '') || ',%',
  'oasis_drift_watch_ro defaults transactions to read-only'
);

select ok(
  not exists (
    select 1
    from pg_auth_members m
    join pg_roles member on member.oid = m.member
    where member.rolname = 'oasis_drift_watch_ro'
  ),
  'oasis_drift_watch_ro has no parent-role memberships'
);

select ok(
  has_table_privilege('oasis_drift_watch_ro', 'supabase_migrations.schema_migrations', 'SELECT'),
  'oasis_drift_watch_ro can read migration ledger'
);

select ok(
  has_table_privilege('oasis_drift_watch_ro', 'storage.buckets', 'SELECT'),
  'oasis_drift_watch_ro can read storage.buckets table privilege'
);

select ok(
  not has_table_privilege('oasis_drift_watch_ro', 'storage.objects', 'SELECT'),
  'oasis_drift_watch_ro cannot SELECT storage.objects'
);

select ok(
  not has_table_privilege('oasis_drift_watch_ro', 'public.companies', 'SELECT'),
  'oasis_drift_watch_ro cannot SELECT public.companies'
);

select ok(
  not has_table_privilege('oasis_drift_watch_ro', 'auth.users', 'SELECT'),
  'oasis_drift_watch_ro cannot SELECT auth.users'
);

select ok(
  not has_schema_privilege('oasis_drift_watch_ro', 'public', 'USAGE'),
  'oasis_drift_watch_ro does not require public schema USAGE'
);

select ok(
  has_schema_privilege('oasis_drift_watch_ro', 'storage', 'USAGE'),
  'oasis_drift_watch_ro has storage schema USAGE'
);

select ok(
  has_schema_privilege('oasis_drift_watch_ro', 'supabase_migrations', 'USAGE'),
  'oasis_drift_watch_ro has supabase_migrations schema USAGE'
);

select ok(
  (
    select count(*)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'p')
      and n.nspname in ('public', 'auth', 'storage')
      and has_table_privilege('oasis_drift_watch_ro', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE')
  ) = 0,
  'oasis_drift_watch_ro has zero DML on public/auth/storage tables'
);

select ok(
  (
    select count(*)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'p')
      and n.nspname in ('public', 'auth')
      and has_table_privilege('oasis_drift_watch_ro', c.oid, 'SELECT')
  ) = 0,
  'oasis_drift_watch_ro has zero SELECT on public/auth application tables'
);

select policies_are(
  'storage',
  'buckets',
  array['oasis_drift_watch_ro_select_buckets'],
  'only the narrowly scoped Drift Watch bucket policy is added on storage.buckets'
);

set role oasis_drift_watch_ro;

select ok(
  (select count(*) >= 0 from storage.buckets),
  'oasis_drift_watch_ro can read storage.buckets rows under RLS'
);

select ok(
  (select count(*) >= 0 from supabase_migrations.schema_migrations),
  'oasis_drift_watch_ro can read migration ledger rows'
);

select throws_ok(
  $$ select count(*) from storage.objects $$,
  '42501',
  null,
  'oasis_drift_watch_ro cannot read storage.objects rows'
);

select throws_ok(
  $$ select count(*) from public.companies $$,
  '42501',
  null,
  'oasis_drift_watch_ro cannot read public.companies rows'
);

reset role;

select * from finish();
