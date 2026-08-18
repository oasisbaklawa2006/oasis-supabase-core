-- Contract for migration 20260817120300_whatsapp_packet_processor_service_role_privileges.sql.
-- Assert the explicit table ACL, not effective role privilege: Supabase's
-- service_role may bypass RLS, so has_table_privilege() is too broad for this
-- least-authority contract.
begin;
select plan(10);

select ok(exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_commercial_evidence'
    and r.rolname='service_role' and acl.privilege_type='SELECT'
), 'service_role has an explicit SELECT grant on immutable commercial evidence');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_commercial_evidence'
    and r.rolname='service_role' and acl.privilege_type='UPDATE'
), 'service_role has no explicit UPDATE grant on immutable commercial evidence');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_commercial_evidence'
    and r.rolname='service_role' and acl.privilege_type='DELETE'
), 'service_role has no explicit DELETE grant on immutable commercial evidence');

select ok(exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='service_role' and acl.privilege_type='SELECT'
), 'service_role has an explicit SELECT grant on packet AI results for idempotency');

select ok(exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='service_role' and acl.privilege_type='INSERT'
), 'service_role has an explicit INSERT grant to append packet AI results');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='service_role' and acl.privilege_type='UPDATE'
), 'service_role has no explicit UPDATE grant on packet AI results');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='service_role' and acl.privilege_type='DELETE'
), 'service_role has no explicit DELETE grant on packet AI results');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='authenticated' and acl.privilege_type='INSERT'
), 'authenticated has no explicit INSERT grant on packet AI results');

select ok(not exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='anon' and acl.privilege_type='INSERT'
), 'anon has no explicit INSERT grant on packet AI results');

select ok(exists(
  select 1
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(c.relacl) acl
  join pg_roles r on r.oid=acl.grantee
  where n.nspname='public' and c.relname='whatsapp_packet_ai_interpretations'
    and r.rolname='authenticated' and acl.privilege_type='SELECT'
), 'authenticated has the explicit SELECT grant consumed through RLS');

select * from finish();
rollback;
