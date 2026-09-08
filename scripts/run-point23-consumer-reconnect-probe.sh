#!/usr/bin/env bash
# Disposable local Central/AI Studio reconnect-replay transport probe.
# Requires canonical local Supabase (migration CI clean-replay or `supabase start`).
# Does not mutate production. Skips transport tests when env is unavailable.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v supabase >/dev/null 2>&1; then
  echo "POINT23 TRANSPORT PROBE: supabase CLI missing — running disposable in-process probes only" >&2
  deno test contracts/point23/realtimeChannelContract.test.ts contracts/point23/consumerReconnectReplayProbe.test.ts
  exit 0
fi

if ! supabase status -o json >/tmp/point23-supabase-status.json 2>/dev/null; then
  echo "POINT23 TRANSPORT PROBE: local Supabase unavailable — running disposable in-process probes only" >&2
  deno test contracts/point23/realtimeChannelContract.test.ts contracts/point23/consumerReconnectReplayProbe.test.ts
  exit 0
fi

export POINT23_PROBE_SUPABASE_URL="$(jq -r '.API_URL' /tmp/point23-supabase-status.json)"
export POINT23_PROBE_SERVICE_ROLE_KEY="$(jq -r '.SERVICE_ROLE_KEY' /tmp/point23-supabase-status.json)"
export POINT23_PROBE_ANON_KEY="$(jq -r '.ANON_KEY' /tmp/point23-supabase-status.json)"
export POINT23_PROBE_JWT_SECRET="$(jq -r '.JWT_SECRET' /tmp/point23-supabase-status.json)"

echo "POINT23 TRANSPORT PROBE: disposable local authority at ${POINT23_PROBE_SUPABASE_URL}"

deno test --allow-env --allow-net \
  contracts/point23/realtimeChannelContract.test.ts \
  contracts/point23/consumerReconnectReplayProbe.test.ts \
  contracts/point23/localSnapshotReconnectProbe.test.ts

echo 'Point23 consumer reconnect/replay probe passed.'
