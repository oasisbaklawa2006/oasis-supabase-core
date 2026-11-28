#!/usr/bin/env bash
# Restore only into disposable, networkless PostgreSQL containers. Never a hosted DSN.
set -euo pipefail
umask 077
export LC_ALL=C
image='supabase/postgres@sha256:e7c227a2ff58a32e9cc32b8bc63aa63eb4af8d35d3a18aecbe610f4fe9933c89'
private="$(mktemp -d "$RUNNER_TEMP/genie-qa-restore-engine.XXXXXX")"
containers=()
cleanup() {
  local status=$? cid
  trap - EXIT
  for cid in "${containers[@]}"; do
    docker rm -fv "$cid" >/dev/null 2>&1 || {
      if docker inspect "$cid" >/dev/null 2>&1; then status=1; fi
    }
  done
  rm -rf -- "$private"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() {
  echo "::error::$1"
  # Only generated synthetic CI fixtures may emit diagnostic contents.
  if [[ "${rehearsal_mode:-}" == --smoke ]]; then
    local log cid
    for log in "$private"/*.log; do
      [[ -f "$log" ]] || continue
      printf '%s\n' "--- $(basename "$log") ---"
      tail -n 30 "$log"
    done
    for cid in "${containers[@]}"; do docker logs --tail 20 "$cid" 2>&1 || true; done
  fi
  exit 1
}
rehearsal_mode="${1:-}"
docker pull --platform linux/amd64 "$image" >/dev/null || fail QA_REHEARSAL_IMAGE_PULL_FAILED
start_cluster() {
  local role="$1" cid ready=0
  [[ "$role" == qa_rehearsal_admin || "$role" == qa_fixture_admin ]]
  cid="$(docker run --detach --platform linux/amd64 --pull never \
    --network none --read-only --user postgres --cap-drop ALL \
    --security-opt no-new-privileges --pids-limit 256 --memory 4g --shm-size 256m \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=2g \
    --entrypoint bash "$image" -c '
      set -euo pipefail
      umask 077
      mkdir -p /tmp/qa-socket
      initdb -D /tmp/qa-data --username="$1" --auth=trust --encoding=UTF8 \
        --locale=en_US.UTF-8 --locale-provider=icu --icu-locale=en-US >/tmp/init.log 2>&1 || { cat /tmp/init.log >&2; exit 1; }
      exec postgres -D /tmp/qa-data -c listen_addresses= -c unix_socket_directories=/tmp/qa-socket \
        -c timezone=UTC -c shared_preload_libraries=pg_stat_statements \
        -c log_statement=none -c log_min_error_statement=panic
    ' bash "$role")" || fail QA_REHEARSAL_CONTAINER_START_FAILED
  containers+=("$cid")
  [[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cid")" == none &&
     "$(docker inspect --format '{{.HostConfig.Privileged}}' "$cid")" == false &&
     "$(docker inspect --format '{{len .HostConfig.Binds}}' "$cid")" == 0 &&
     "$(docker inspect --format '{{len .HostConfig.PortBindings}}' "$cid")" == 0 ]] \
    || fail QA_REHEARSAL_ISOLATION_FAILED
  for _ in {1..90}; do
    if docker exec "$cid" pg_isready -h /tmp/qa-socket -U "$role" -d postgres >/dev/null 2>&1; then
      ready=1; break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$cid")" != true ]]; then break; fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || fail QA_REHEARSAL_CLUSTER_NOT_READY
  db_exec "$cid" "$role" psql -X -qAt -v ON_ERROR_STOP=1 -c "select current_setting('server_version_num')" \
    >"$private/version" 2>/dev/null || fail QA_REHEARSAL_VERSION_READ_FAILED
  grep -Eq '^170012$' "$private/version" || fail QA_REHEARSAL_WRONG_SERVER_VERSION
  cluster="$cid"
}
db_exec() {
  local cid="$1" role="$2"
  shift 2
  docker exec -i -e PGHOST=/tmp/qa-socket -e PGPORT=5432 -e PGDATABASE=postgres \
    -e PGUSER="$role" -e PGTZ=UTC "$cid" "$@"
}
census() {
  db_exec "$1" "$2" psql -X -qAt -v ON_ERROR_STOP=1 -c "$(cat "$3")"
}
ledger() {
  db_exec "$1" "$2" psql -X -qAt -v ON_ERROR_STOP=1 \
    -c 'select version from supabase_migrations.schema_migrations order by version'
}
extensions() {
  db_exec "$1" "$2" psql -X -qAt -v ON_ERROR_STOP=1 \
    -c "select extname || '|' || extversion || '|' || n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace order by extname"
}
restore_archive() {
  local archive="$1" sql="$2" expected_extensions="$3" cid role=qa_rehearsal_admin
  start_cluster "$role"
  cid="$cluster"
  db_exec "$cid" "$role" psql -X -q -v ON_ERROR_STOP=1 --single-transaction -f - \
    <"$archive/roles.sql" >"$private/roles-restore.log" 2>&1 \
    || fail QA_REHEARSAL_ROLE_RESTORE_FAILED
  db_exec "$cid" "$role" psql -X -q -v ON_ERROR_STOP=1 \
    -c 'alter database postgres owner to postgres' >"$private/database-owner.log" 2>&1 \
    || fail QA_REHEARSAL_DATABASE_OWNER_FAILED
  db_exec "$cid" "$role" pg_restore --list <"$archive/database.dump" >"$private/restore.toc" 2>"$private/toc.log" \
    || fail QA_REHEARSAL_TOC_FAILED
  # initdb provides an empty public schema. Remove it only if the actual TOC recreates it.
  if grep -Eq '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - public ' "$private/restore.toc"; then
    db_exec "$cid" "$role" psql -X -q -v ON_ERROR_STOP=1 -c 'drop schema public' \
      >"$private/public-schema.log" 2>&1 || fail QA_REHEARSAL_PUBLIC_SCHEMA_FAILED
  fi
  db_exec "$cid" "$role" pg_restore --exit-on-error --single-transaction --dbname=postgres \
    <"$archive/database.dump" >"$private/restore.log" 2>&1 \
    || fail QA_REHEARSAL_DATABASE_RESTORE_FAILED
  echo 'QA_REHEARSAL_FULL_LOGICAL_RESTORE_COMPLETED'
  census "$cid" "$role" "$sql" >"$private/restored-census.json" 2>"$private/census.log" \
    || fail QA_REHEARSAL_CENSUS_FAILED
  cmp -s "$archive/preservation.json" "$private/restored-census.json" \
    || fail QA_REHEARSAL_PROTECTED_STATE_MISMATCH
  ledger "$cid" "$role" >"$private/restored-ledger.txt" 2>"$private/ledger.log" \
    || fail QA_REHEARSAL_LEDGER_FAILED
  cmp -s "$archive/ledger.txt" "$private/restored-ledger.txt" \
    || fail QA_REHEARSAL_LEDGER_MISMATCH
  extensions "$cid" "$role" >"$private/restored-extensions.txt" 2>"$private/extensions.log" \
    || fail QA_REHEARSAL_EXTENSIONS_FAILED
  cmp -s "$expected_extensions" "$private/restored-extensions.txt" \
    || fail QA_REHEARSAL_EXTENSION_PARITY_FAILED
  echo 'QA_REHEARSAL_PROTECTED_ROWS_LEDGER_AND_EXTENSIONS_MATCH'
}
smoke() {
  local sql="$1" expected="$2" fixture="$private/fixture" cid role=qa_fixture_admin table
  mkdir -m 700 "$fixture"
  start_cluster "$role"
  cid="$cluster"
  {
    echo 'create role postgres login; alter database postgres owner to postgres;'
    echo 'create schema auth; create schema storage; create schema supabase_migrations; create schema extensions; create schema vault;'
    echo 'create extension hypopg with schema extensions; create extension index_advisor with schema extensions;'
    echo 'create extension pg_stat_statements with schema extensions; create extension pgcrypto with schema extensions;'
    echo 'create extension supabase_vault with schema vault; create extension "uuid-ossp" with schema extensions;'
    for table in auth.users auth.identities auth.sessions auth.refresh_tokens auth.audit_log_entries \
      public.users public.profiles public.companies public.b2b_applications public.customer_order_drafts \
      public.customer_order_draft_lines public.customer_order_draft_audit_log public.products \
      public.product_pricing_rules public.product_moq_rules public.orders storage.objects; do
      printf 'create table %s (id integer primary key, payload text not null);\n' "$table"
      if [[ "$table" != storage.objects ]]; then printf "insert into %s values (1, 'synthetic QA fixture');\n" "$table"; fi
    done
    echo "create table supabase_migrations.schema_migrations (version text primary key); insert into supabase_migrations.schema_migrations values ('20260101000000'), ('20260102000000');"
  } | db_exec "$cid" "$role" psql -X -q -v ON_ERROR_STOP=1 -f - >"$private/fixture.log" 2>&1 \
    || fail QA_REHEARSAL_FIXTURE_FAILED
  extensions "$cid" "$role" >"$private/fixture-extensions.txt" 2>"$private/fixture-ext.log" \
    || fail QA_REHEARSAL_FIXTURE_EXTENSIONS_FAILED
  cmp -s "$expected" "$private/fixture-extensions.txt" || fail QA_REHEARSAL_FIXTURE_EXTENSION_PARITY_FAILED
  census "$cid" "$role" "$sql" >"$fixture/preservation.json" 2>"$private/fixture-census.log"
  ledger "$cid" "$role" >"$fixture/ledger.txt" 2>"$private/fixture-ledger.log"
  db_exec "$cid" "$role" pg_dump --format=custom --no-password >"$fixture/database.dump" 2>"$private/fixture-dump.log"
  db_exec "$cid" "$role" pg_dumpall --roles-only --no-role-passwords --no-password >"$fixture/roles.sql" 2>"$private/fixture-roles.log"
  restore_archive "$fixture" "$sql" "$expected"
  echo 'QA_REHEARSAL_SYNTHETIC_RESTORE_PASS'
}
case "$1" in
  --archive)
    [[ "$#" == 4 ]] || fail QA_REHEARSAL_INVALID_ARGUMENTS
    restore_archive "$2" "$3" "$4"
    echo 'QA_REHEARSAL_ARCHIVE_RESTORE_PASS'
    ;;
  --smoke)
    [[ "$#" == 3 ]] || fail QA_REHEARSAL_INVALID_ARGUMENTS
    smoke "$2" "$3"
    ;;
  *) fail QA_REHEARSAL_INVALID_MODE ;;
esac
