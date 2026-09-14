#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

fail() {
  echo "PRODUCTION READONLY CREDENTIAL CERTIFICATION FAILED: $*" >&2
  exit 1
}

psql_base=(psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1)

role_name="$("${psql_base[@]}" -c 'select current_user')"
[[ "$role_name" == 'supabase_read_only_user' ]] \
  || fail "credential must connect as supabase_read_only_user; got ${role_name:-missing}"

role_facts="$("${psql_base[@]}" -F '|' -c "
select
  rolsuper,
  rolcreaterole,
  rolcreatedb,
  rolreplication,
  coalesce(array_to_string(rolconfig, ','), ''),
  rolbypassrls
from pg_roles
where rolname = current_user;
")"
IFS='|' read -r is_super can_create_role can_create_db can_replicate role_config bypass_rls <<<"$role_facts"

[[ "$is_super" == 'f' ]] || fail 'read-only credential must not be superuser'
[[ "$can_create_role" == 'f' ]] || fail 'read-only credential must not create roles'
[[ "$can_create_db" == 'f' ]] || fail 'read-only credential must not create databases'
[[ "$can_replicate" == 'f' ]] || fail 'read-only credential must not have replication authority'
[[ ",$role_config," == *",default_transaction_read_only=on,"* ]] \
  || fail 'read-only credential must default every transaction to read-only'

app_dml_count="$("${psql_base[@]}" -c "
select count(*)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p')
  and n.nspname in ('public','auth','storage')
  and has_table_privilege(current_user, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE');
")"
[[ "$app_dml_count" == '0' ]] \
  || fail "read-only credential has DML privilege on ${app_dml_count} application table(s)"

create_facts="$("${psql_base[@]}" -F '|' -c "
select
  has_database_privilege(current_user, current_database(), 'CREATE'),
  has_schema_privilege(current_user, 'public', 'CREATE');
")"
IFS='|' read -r can_create_database_object can_create_public_object <<<"$create_facts"
[[ "$can_create_database_object" == 'f' ]] || fail 'read-only credential must not CREATE in the production database'
[[ "$can_create_public_object" == 'f' ]] || fail 'read-only credential must not CREATE in public schema'

# Permission proof, independent of the role's default_transaction_read_only setting.
# WHERE false guarantees that even a misconfigured writable credential changes zero rows.
set +e
write_probe_output="$("${psql_base[@]}" -c "set default_transaction_read_only = off; update public.companies set id = id where false;" 2>&1)"
write_probe_status=$?
set -e
if [[ "$write_probe_status" -eq 0 ]]; then
  fail 'zero-row UPDATE unexpectedly succeeded after disabling the session read-only default; credential has write authority'
fi
if [[ "$write_probe_output" != *'permission denied'* && "$write_probe_output" != *'read-only transaction'* ]]; then
  fail 'zero-row UPDATE failed for an unexpected reason; cannot certify the credential boundary'
fi

printf 'Production read-only credential certified: role=%s application_dml=0 create_db=f create_public=f bypass_rls=%s default_transaction_read_only=on\n' \
  "$role_name" "$bypass_rls"
