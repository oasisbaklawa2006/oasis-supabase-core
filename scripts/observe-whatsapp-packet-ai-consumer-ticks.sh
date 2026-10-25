#!/usr/bin/env bash
# Read-only bounded observation of scheduler-submitted whatsapp-packet-ai-consumer ticks.
# Polls the recorded pg_net responses until the required number of consecutive healthy
# minutes is proven, a regression appears, or the time budget is spent.
# usage: observe-whatsapp-packet-ai-consumer-ticks.sh <since_timestamp> <required_ticks> <max_minutes> <out_dir>
# Test seam: OBSERVE_RESPONSES_FILE replaces the database query and disables polling; OBSERVE_NOW pins the clock.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <since_timestamp> <required_ticks> <max_minutes> <out_dir>" >&2
  exit 2
fi
since="$1"
required="$2"
max_minutes="$3"
out_dir="$4"
[[ "$required" =~ ^[1-9][0-9]*$ && "$max_minutes" =~ ^[1-9][0-9]*$ ]] || exit 2

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out_dir"
responses="$out_dir/consumer-tick-responses.json"
verdict="$out_dir/consumer-tick-verdict.json"
expected="${OBSERVE_EXPECTED_PER_MINUTE:-}"

deadline=$((SECONDS + max_minutes * 60))
rc=3
while :; do
  if [[ -n "${OBSERVE_RESPONSES_FILE:-}" ]]; then
    cp "$OBSERVE_RESPONSES_FILE" "$responses"
  else
    psql "$SUPABASE_DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 \
      -f "$tools_dir/sql/observe-whatsapp-packet-ai-consumer-production-ticks.sql" >"$responses"
  fi
  if [[ -z "$expected" ]]; then
    expected="$(psql "$SUPABASE_DB_URL" -X -t -A -v ON_ERROR_STOP=1 \
      -c "select count(*) from cron.job where active and command ilike '%consumer_tick%'")"
  fi
  if [[ -n "${OBSERVE_NOW:-}" ]]; then
    now="$OBSERVE_NOW"
  else
    # The database clock stamps the responses, so it judges which minutes have closed.
    now="$(psql "$SUPABASE_DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c 'select clock_timestamp()')"
  fi
  [[ "$expected" =~ ^[1-9][0-9]*$ ]] || { echo "OBSERVATION_NO_ACTIVE_CONSUMER_CRON" >&2; exit 1; }
  set +e
  python3 "$tools_dir/whatsapp-packet-ai-consumer-release-evidence.py" evaluate-ticks "$responses" \
    --since "$since" --expected-per-minute "$expected" --required "$required" --now "$now" >"$verdict"
  rc=$?
  set -e
  jq -c '{verdict, trailingHealthyTicks, longestHealthyRun, defects: (.defectResponses | length)}' "$verdict"
  if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
    exit "$rc"
  fi
  if [[ -n "${OBSERVE_RESPONSES_FILE:-}" || "$SECONDS" -ge "$deadline" ]]; then
    echo "OBSERVATION_INSUFFICIENT: fewer than $required consecutive healthy ticks within $max_minutes minutes" >&2
    exit 3
  fi
  sleep 60
done
