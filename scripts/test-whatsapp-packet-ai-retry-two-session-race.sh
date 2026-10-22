#!/usr/bin/env bash
# Concurrency proof for bounded retry / dead-letter of the WhatsApp packet-AI
# dispatch outbox (migration 20261022120000_whatsapp_packet_ai_dispatch_bounded_retry).
#
#   A. duplicate delivery: two sessions report the same failure with the same
#      lease token at the same time -> exactly one is accepted, the budget is
#      spent exactly once.
#   B. exhaustion race: two sessions report the final allowed failure at the
#      same time -> exactly one dead-letter transition, one audit event and one
#      platform dead-letter entry.
#   C. claim storm: many concurrent claimers over a small queue -> every job is
#      leased at most once.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "WHATSAPP_PACKET_AI_RETRY_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'
command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/wa-packet-ai-retry-race.XXXXXX)"
cleanup() {
  rm -rf "$coord_dir"
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

psql_cmd() {
  PGCONNECT_TIMEOUT=10 \
    PGOPTIONS='-c lock_timeout=10s -c statement_timeout=60s' \
    psql "$db_url" -X -v ON_ERROR_STOP=1 "$@"
}

prefix='86512200-0000-0000-0000'
fixture_ids() { seq -f "${prefix}-%012g" "$1" "$2"; }

reset_fixtures() {
  psql_cmd -q <<SQL >/dev/null
DELETE FROM public.dead_letter_entries WHERE source_table = 'whatsapp_packet_ai_dispatch_jobs'
  AND source_record_id IN (SELECT id::text FROM public.whatsapp_packet_ai_dispatch_jobs WHERE logical_dispatch_key LIKE 'race:retry:%');
ALTER TABLE public.whatsapp_packet_ai_dispatch_dead_letter_events DISABLE TRIGGER whatsapp_packet_ai_dispatch_dead_letter_events_append_only;
DELETE FROM public.whatsapp_packet_ai_dispatch_dead_letter_events
  WHERE job_id IN (SELECT id FROM public.whatsapp_packet_ai_dispatch_jobs WHERE logical_dispatch_key LIKE 'race:retry:%');
ALTER TABLE public.whatsapp_packet_ai_dispatch_dead_letter_events ENABLE TRIGGER whatsapp_packet_ai_dispatch_dead_letter_events_append_only;
DELETE FROM public.whatsapp_packet_ai_dispatch_jobs WHERE logical_dispatch_key LIKE 'race:retry:%';
DELETE FROM public.whatsapp_message_packets WHERE contact_id::text LIKE '${prefix}-%';
DELETE FROM public.whatsapp_contacts WHERE id::text LIKE '${prefix}-%';
SQL
}

# seed_jobs <count> : one contact + packet + QUEUED bounded job per index.
seed_jobs() {
  psql_cmd -q <<SQL >/dev/null
INSERT INTO public.whatsapp_contacts(id, phone_number, customer_name)
SELECT ('${prefix}-' || lpad(n::text, 12, '0'))::uuid, '91965122' || lpad(n::text, 4, '0'), 'retry race ' || n
FROM generate_series(1, $1) n;

INSERT INTO public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status, ai_dispatch_revision
)
SELECT ('${prefix}-1' || lpad(n::text, 11, '0'))::uuid, ('${prefix}-' || lpad(n::text, 12, '0'))::uuid,
       '{}'::jsonb, 1, statement_timestamp(), statement_timestamp(), 'closed', 1
FROM generate_series(1, $1) n;

INSERT INTO public.whatsapp_packet_ai_dispatch_jobs(
  id, packet_id, packet_revision, logical_dispatch_key, state, attempt_count, next_retry_at, execution_kind
)
SELECT ('${prefix}-2' || lpad(n::text, 11, '0'))::uuid, ('${prefix}-1' || lpad(n::text, 11, '0'))::uuid,
       1, 'race:retry:' || n, 'QUEUED', 0, statement_timestamp() - interval '1 second', 'PACKET'
FROM generate_series(1, $1) n;
SQL
}

# claim_one : prints "id|lease_token|packet_revision" for the claimed job.
claim_one() {
  psql_cmd -Atq -F '|' -c "
    SELECT id, lease_token, packet_revision
    FROM public.claim_whatsapp_packet_ai_dispatch_job(120)
    WHERE id IS NOT NULL;"
}

retry_call() { # <id> <token> <revision> <code>
  psql_cmd -Atq -c "
    SELECT public.retry_whatsapp_packet_ai_dispatch_job(
      '$1'::uuid, '$2'::uuid, $3, '$4', 'race detail', false);"
}

reset_fixtures

# ---------------------------------------------------------------- A: duplicate
seed_jobs 1
IFS='|' read -r job token revision <<<"$(claim_one)"
[[ -n "$job" ]] || fail 'scenario A: no job claimed'

for i in 1 2 3 4; do
  retry_call "$job" "$token" "$revision" GEMINI_UNAVAILABLE >"$coord_dir/a_$i.out" 2>"$coord_dir/a_$i.err" &
done
wait
accepted="$(cat "$coord_dir"/a_*.out | grep -c '^t$' || true)"
[[ "$accepted" == '1' ]] || fail "scenario A: expected exactly one accepted duplicate, got $accepted"
state_budget="$(psql_cmd -Atq -F '|' -c "SELECT state, retry_budget_used FROM public.whatsapp_packet_ai_dispatch_jobs WHERE id='$job'")"
[[ "$state_budget" == 'RETRY|1' ]] || fail "scenario A: expected RETRY|1, got $state_budget"

# ------------------------------------------------------------- B: exhaustion
reset_fixtures
seed_jobs 1
IFS='|' read -r job token revision <<<"$(claim_one)"
[[ -n "$job" ]] || fail 'scenario B: no job claimed'
psql_cmd -q -c "UPDATE public.whatsapp_packet_ai_dispatch_jobs SET retry_budget_used = 9 WHERE id='$job'" >/dev/null

for i in 1 2 3 4; do
  retry_call "$job" "$token" "$revision" GEMINI_UNAVAILABLE >"$coord_dir/b_$i.out" 2>"$coord_dir/b_$i.err" &
done
wait
accepted="$(cat "$coord_dir"/b_*.out | grep -c '^t$' || true)"
[[ "$accepted" == '1' ]] || fail "scenario B: expected exactly one dead-letter transition, got $accepted"
counts="$(psql_cmd -Atq -F '|' -c "
  SELECT j.state,
         (SELECT count(*) FROM public.whatsapp_packet_ai_dispatch_dead_letter_events e WHERE e.job_id = j.id AND e.event_type = 'DEAD_LETTERED'),
         (SELECT count(*) FROM public.dead_letter_entries d WHERE d.source_record_id = j.id::text AND d.status = 'open')
  FROM public.whatsapp_packet_ai_dispatch_jobs j WHERE j.id = '$job'")"
[[ "$counts" == 'DEAD_LETTERED|1|1' ]] || fail "scenario B: expected DEAD_LETTERED|1|1, got $counts"

# ---------------------------------------------------------------- C: storm
reset_fixtures
seed_jobs 6
for i in $(seq 1 12); do
  claim_one >"$coord_dir/c_$i.out" 2>"$coord_dir/c_$i.err" &
done
wait
claimed_ids="$(cat "$coord_dir"/c_*.out | cut -d'|' -f1 | grep -E '^[0-9a-f-]{36}$' | sort || true)"
total="$(printf '%s\n' "$claimed_ids" | grep -c . || true)"
distinct="$(printf '%s\n' "$claimed_ids" | sort -u | grep -c . || true)"
[[ "$total" == '6' && "$distinct" == '6' ]] || fail "scenario C: expected 6 distinct leases, got total=$total distinct=$distinct"

reset_fixtures
echo 'WHATSAPP_PACKET_AI_RETRY_TWO_SESSION_RACE: PASS'
