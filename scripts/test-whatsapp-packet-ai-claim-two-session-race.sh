#!/usr/bin/env bash
# Two-session concurrency proof for the canonical WhatsApp packet-AI claim path.
# Session A claims the only eligible dispatch job and deliberately holds the
# transaction open. Session B must skip the locked row and receive no claim.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "WHATSAPP_PACKET_AI_CLAIM_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'
command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/wa-packet-ai-claim-race.XXXXXX)"
cleanup() {
  rm -rf "$coord_dir"
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

psql_cmd() {
  PGCONNECT_TIMEOUT=10 \
    PGOPTIONS='-c lock_timeout=5s -c statement_timeout=60s' \
    psql "$db_url" -X -v ON_ERROR_STOP=1 "$@"
}

contact_id='86511400-0000-0000-0000-000000000001'
packet_id='86511400-0000-0000-0000-000000000010'
job_id='86511400-0000-0000-0000-000000000020'
evidence_table='wa_packet_ai_claim_race_evidence'
a_log="$coord_dir/session_a.log"
a_out="$coord_dir/session_a.out"

psql_cmd <<SQL >/dev/null
DROP TABLE IF EXISTS public.${evidence_table};
CREATE TABLE public.${evidence_table}(
  scenario text PRIMARY KEY,
  winner_id uuid,
  competitor_id uuid,
  final_state text NOT NULL,
  attempt_count integer NOT NULL,
  lease_token_present boolean NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

DELETE FROM public.whatsapp_packet_ai_dispatch_jobs WHERE id='${job_id}';
DELETE FROM public.whatsapp_message_packets WHERE id='${packet_id}';
DELETE FROM public.whatsapp_contacts WHERE id='${contact_id}';

INSERT INTO public.whatsapp_contacts(id, phone_number, customer_name)
VALUES ('${contact_id}', '919651140001', 'Canonical claim race contact');

INSERT INTO public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count,
  first_message_at, last_message_at, status, ai_dispatch_revision
) VALUES (
  '${packet_id}', '${contact_id}', '{}'::jsonb, 1,
  statement_timestamp(), statement_timestamp(), 'ready', 1
);

INSERT INTO public.whatsapp_packet_ai_dispatch_jobs(
  id, packet_id, packet_revision, logical_dispatch_key, state,
  attempt_count, next_retry_at, execution_kind
) VALUES (
  '${job_id}', '${packet_id}', 1, 'race:canonical-claim:86511400',
  'QUEUED', 0, statement_timestamp(), 'PACKET'
);
SQL

PGAPPNAME='wa-packet-ai-race-a' psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 >"$a_out" 2>"$a_log" <<SQL &
BEGIN;
SELECT id::text
FROM public.claim_whatsapp_packet_ai_dispatch_job(120)
LIMIT 1;
SELECT pg_sleep(2);
COMMIT;
SQL
a_pid=$!

a_holding='f'
for _ in $(seq 1 100); do
  a_holding="$(psql_cmd -Atq -c "
    SELECT EXISTS (
      SELECT 1
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND application_name = 'wa-packet-ai-race-a'
        AND state = 'active'
        AND query ILIKE '%pg_sleep%'
    );
  ")"
  [[ "$a_holding" == 't' ]] && break
  sleep 0.05
done
[[ "$a_holding" == 't' ]] || fail "session A never reached post-claim hold boundary: $(cat "$a_log")"

competitor_id="$(PGAPPNAME='wa-packet-ai-race-b' psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 -c "
  SELECT id::text
  FROM public.claim_whatsapp_packet_ai_dispatch_job(120)
  LIMIT 1;
")"

wait "$a_pid" || fail "session A failed: $(cat "$a_log")"

winner_id="$(grep -E '^[0-9a-f-]{36}$' "$a_out" | head -n1 || true)"
[[ "$winner_id" == "$job_id" ]] || fail "session A did not claim expected job: winner=${winner_id:-<none>}"
[[ -z "$competitor_id" ]] || fail "session B concurrently claimed locked job: $competitor_id"

psql_cmd <<SQL >/dev/null
INSERT INTO public.${evidence_table}(
  scenario, winner_id, competitor_id, final_state, attempt_count, lease_token_present
)
SELECT
  'canonical_claim_skip_locked',
  '${winner_id}'::uuid,
  NULLIF('${competitor_id}', '')::uuid,
  state,
  attempt_count,
  lease_token IS NOT NULL
FROM public.whatsapp_packet_ai_dispatch_jobs
WHERE id='${job_id}';

DELETE FROM public.whatsapp_packet_ai_dispatch_jobs WHERE id='${job_id}';
DELETE FROM public.whatsapp_message_packets WHERE id='${packet_id}';
DELETE FROM public.whatsapp_contacts WHERE id='${contact_id}';
SQL

recorded="$(psql_cmd -Atq -c "SELECT count(*) FROM public.${evidence_table} WHERE scenario='canonical_claim_skip_locked'")"
[[ "$recorded" == '1' ]] || fail 'race evidence was not recorded'

echo 'WHATSAPP_PACKET_AI_CLAIM_TWO_SESSION_RACE: PASS'
