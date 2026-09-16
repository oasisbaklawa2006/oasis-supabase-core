#!/usr/bin/env bash
# Certify the Production Migration Drift Watch database credential.
# Expects SUPABASE_DB_URL to connect as oasis_drift_watch_ro (or a superuser
# session with PGOPTIONS=-c role=oasis_drift_watch_ro for local replay tests).
set -euo pipefail

fail() {
  echo "PRODUCTION DRIFT WATCH CREDENTIAL CERTIFICATION FAILED: $*" >&2
  exit 1
}

[[ -n "${SUPABASE_DB_URL:-}" ]] || fail 'SUPABASE_DB_URL is required'

role_name="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_user')"
[[ "$role_name" == 'oasis_drift_watch_ro' ]] \
  || fail "credential must connect as oasis_drift_watch_ro; got ${role_name:-missing}"

role_facts="$(psql "$SUPABASE_DB_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 -c "
select
  rolsuper,
  rolcreaterole,
  rolcreatedb,
  rolreplication,
  coalesce(array_to_string(rolconfig, ','), ''),
  rolbypassrls,
  rolcanlogin,
  rolinherit
from pg_roles
where rolname = current_user;
")"
IFS='|' read -r is_super can_create_role can_create_db can_replicate role_config bypass_rls can_login inherits <<<"$role_facts"
[[ "$is_super" == 'f' ]] || fail 'credential must not be superuser'
[[ "$can_create_role" == 'f' ]] || fail 'credential must not create roles'
[[ "$can_create_db" == 'f' ]] || fail 'credential must not create databases'
[[ "$can_replicate" == 'f' ]] || fail 'credential must not have replication authority'
[[ ",$role_config," == *",default_transaction_read_only=on,"* ]] \
  || fail 'credential must default every transaction to read-only'
[[ "$bypass_rls" == 'f' ]] || fail 'credential must not bypass row-level security'
[[ "$inherits" == 'f' ]] || fail 'credential must not inherit parent-role privileges'

dangerous_settable_roles="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
with recursive settable(role_oid) as (
  select m.roleid
  from pg_auth_members m
  join pg_roles login on login.oid = m.member
  where login.rolname = current_user::name
  union
  select m.roleid
  from pg_auth_members m
  join settable s on m.member = s.role_oid
)
select count(*)
from settable s
join pg_roles r on r.oid = s.role_oid
where r.rolsuper
   or r.rolcreatedb
   or r.rolcreaterole
   or r.rolreplication
   or r.rolbypassrls;
")"
[[ "$dangerous_settable_roles" == '0' ]] \
  || fail "credential can SET ROLE into ${dangerous_settable_roles} privileged role(s)"

forbidden_memberships="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
select count(*)
from pg_auth_members m
join pg_roles member on member.oid = m.member
join pg_roles parent on parent.oid = m.roleid
where member.rolname = current_user
  and parent.rolname in ('anon', 'authenticated', 'service_role', 'supabase_admin', 'postgres');
")"
[[ "$forbidden_memberships" == '0' ]] \
  || fail "credential must not be a member of anon/authenticated/service_role or platform admin roles"

app_dml_count="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
select count(*)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p')
  and n.nspname in ('public','auth','storage')
  and has_table_privilege(current_user, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE');
")"
[[ "$app_dml_count" == '0' ]] \
  || fail "credential has DML privilege on ${app_dml_count} application table(s)"

create_facts="$(psql "$SUPABASE_DB_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 -c "
select
  has_database_privilege(current_user, current_database(), 'CREATE'),
  has_schema_privilege(current_user, 'public', 'CREATE'),
  has_schema_privilege(current_user, 'storage', 'CREATE');
")"
IFS='|' read -r can_create_database_object can_create_public_object can_create_storage_object <<<"$create_facts"
[[ "$can_create_database_object" == 'f' ]] || fail 'credential must not CREATE in the production database'
[[ "$can_create_public_object" == 'f' ]] || fail 'credential must not CREATE in public schema'
[[ "$can_create_storage_object" == 'f' ]] || fail 'credential must not CREATE in storage schema'

objects_select="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
select has_table_privilege(current_user, 'storage.objects', 'SELECT');
")"
[[ "$objects_select" == 'f' ]] \
  || fail 'credential must not have SELECT on storage.objects'

app_select_count="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
select count(*)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p')
  and n.nspname in ('public','auth')
  and has_table_privilege(current_user, c.oid, 'SELECT');
")"
[[ "$app_select_count" == '0' ]] \
  || fail "credential has SELECT on ${app_select_count} public/auth application table(s)"

governed_select_facts="$(psql "$SUPABASE_DB_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 -c "
select
  has_table_privilege(current_user, 'storage.buckets', 'SELECT'),
  has_table_privilege(current_user, 'supabase_migrations.schema_migrations', 'SELECT'),
  has_schema_privilege(current_user, 'storage', 'USAGE'),
  has_schema_privilege(current_user, 'supabase_migrations', 'USAGE');
")"
IFS='|' read -r can_select_buckets can_select_migrations can_use_storage can_use_migrations <<<"$governed_select_facts"
[[ "$can_select_buckets" == 't' ]] || fail 'credential must SELECT storage.buckets for governed drift watch'
[[ "$can_select_migrations" == 't' ]] || fail 'credential must SELECT supabase_migrations.schema_migrations'
[[ "$can_use_storage" == 't' ]] || fail 'credential must have USAGE on storage schema'
[[ "$can_use_migrations" == 't' ]] || fail 'credential must have USAGE on supabase_migrations schema'

public_direct_schema_privs="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "
select count(*)
from pg_namespace n
join pg_roles r on r.rolname = current_user
join lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl
  on acl.grantee = r.oid
where n.nspname = 'public'
  and acl.privilege_type in ('USAGE', 'CREATE');
")"
[[ "$public_direct_schema_privs" == '0' ]] \
  || fail "credential must not hold direct public schema privileges (${public_direct_schema_privs})"

# Prove privileges, not merely the role's read-only session default.
set +e
write_probe_output="$(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 \
  -c 'set default_transaction_read_only = off;' \
  -c 'update public.companies set id = id where false;' 2>&1)"
write_probe_status=$?
set -e
if [[ "$write_probe_status" -eq 0 ]]; then
  fail 'zero-row UPDATE unexpectedly succeeded in a writable transaction'
fi
if [[ "$write_probe_output" != *'permission denied'* ]]; then
  fail 'zero-row UPDATE failed for an unexpected reason; boundary cannot be certified'
fi

printf 'Production drift-watch credential certified: role=%s application_dml=0 application_select=0 objects_select=f create_db=f create_public=f create_storage=f bypass_rls=f default_transaction_read_only=on public_direct_schema_privs=0\n' \
  "$role_name"
