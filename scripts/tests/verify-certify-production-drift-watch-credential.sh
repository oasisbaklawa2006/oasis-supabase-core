#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/certify-production-drift-watch-credential.sh"

bash -n "$script"

grep -Fq "oasis_drift_watch_ro" "$script"
grep -Fq 'storage.objects' "$script"
grep -Fq 'supabase_migrations.schema_migrations' "$script"
grep -Fq "has_schema_privilege(current_user, 'public', 'USAGE')" "$script"
grep -Fq 'permission denied' "$script"
grep -Fq 'default_transaction_read_only=on' "$script"

workflow="$repo_root/.github/workflows/production-migration-drift-watch.yml"
grep -Fq 'scripts/certify-production-drift-watch-credential.sh' "$workflow"
if grep -Fq 'supabase_read_only_user' "$workflow"; then
  echo 'drift-watch workflow must not depend on supabase_read_only_user' >&2
  exit 1
fi

migration="$repo_root/supabase/migrations/20260916200000_oasis_drift_watch_ro_authority.sql"
grep -Fq 'CREATE ROLE oasis_drift_watch_ro' "$migration"
grep -Fq 'NOBYPASSRLS' "$migration"
grep -Fq 'NOLOGIN' "$migration"
grep -Fq 'GRANT SELECT ON TABLE storage.buckets' "$migration"
grep -Fq 'GRANT SELECT ON TABLE supabase_migrations.schema_migrations' "$migration"
grep -Fq 'oasis_drift_watch_ro_select_buckets' "$migration"
if grep -Eiv '^[[:space:]]*--' "$migration" | grep -Eiq 'password[[:space:]]*=|secret[[:space:]]*='; then
  echo 'migration must not embed password or secret literals' >&2
  exit 1
fi

echo 'certify-production-drift-watch-credential regression passed.'
