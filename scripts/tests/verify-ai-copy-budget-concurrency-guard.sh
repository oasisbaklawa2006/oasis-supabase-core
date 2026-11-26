#!/usr/bin/env bash
# Negative tests for the disposable-database guard of verify-ai-copy-budget-concurrency.sh.
# Needs NO database: every case must be refused (exit 2) before any connection is attempted.
set -u
script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/verify-ai-copy-budget-concurrency.sh"
fail=0
expect_refused() {
  local label="$1"; shift
  local out rc
  out="$(env -i PATH="$PATH" "$@" bash "$script" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q '^REFUSED' <<<"$out"; then
    echo "ok   refused: $label"
  else
    echo "FAIL not refused: $label (rc=$rc): $out" >&2; fail=1
  fi
}
base=(PGUSER=postgres PGPORT=5432 PGDATABASE=disposable_x)
expect_refused "remote host"                      "${base[@]}" PGHOST=db.example.com
expect_refused "mixed local+remote host list"     "${base[@]}" PGHOST=/tmp,remote.example
expect_refused "remote+local host list"           "${base[@]}" PGHOST=remote.example,/tmp
expect_refused "localhost+remote host list"       "${base[@]}" PGHOST=localhost,db.example.com
expect_refused "host list with space"             "${base[@]}" "PGHOST=/tmp, localhost"
expect_refused "shell metacharacter in host"      "${base[@]}" "PGHOST=/tmp;x"
expect_refused "non-disposable database name"     PGUSER=postgres PGPORT=5432 PGHOST=localhost PGDATABASE=postgres
expect_refused "production-looking database name" PGUSER=postgres PGPORT=5432 PGHOST=localhost PGDATABASE=prod_main
expect_refused "port list"                        PGUSER=postgres PGPORT=5432,5433 PGHOST=localhost PGDATABASE=disposable_x
expect_refused "DATABASE_URL set"                 "${base[@]}" PGHOST=localhost DATABASE_URL=postgres://x/y
expect_refused "PGSERVICE set"                    "${base[@]}" PGHOST=localhost PGSERVICE=prod
expect_refused "PGHOSTADDR set"                   "${base[@]}" PGHOST=localhost PGHOSTADDR=10.0.0.1
expect_refused "too few sessions"                 "${base[@]}" PGHOST=localhost SESSIONS=2
[ "$fail" -eq 0 ] && echo "AI_COPY_BUDGET_CONCURRENCY_GUARD_PASS"
exit "$fail"
