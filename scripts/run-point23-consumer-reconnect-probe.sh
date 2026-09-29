#!/usr/bin/env bash
# Disposable local Central/AI Studio reconnect-replay transport probe.
# Requires canonical local Supabase (migration CI clean-replay or `supabase start`).
# Does not mutate production. Skips transport tests when env is unavailable.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v deno >/dev/null 2>&1; then
  echo "POINT23 CONSUMER PROBE: deno is required but not on PATH" >&2
  exit 127
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "POINT23 TRANSPORT PROBE: supabase CLI missing — running disposable in-process probes only" >&2
  deno test contracts/point23/realtimeChannelContract.test.ts contracts/point23/consumerReconnectReplayProbe.test.ts
  exit 0
fi

status_file="$(mktemp)"
cleanup_status_file() {
  rm -f "$status_file"
}
trap cleanup_status_file EXIT

if ! supabase status -o json >"$status_file" 2>/dev/null; then
  echo "POINT23 TRANSPORT PROBE: local Supabase unavailable — running disposable in-process probes only" >&2
  deno test contracts/point23/realtimeChannelContract.test.ts contracts/point23/consumerReconnectReplayProbe.test.ts
  exit 0
fi

export POINT23_PROBE_SUPABASE_URL="$(jq -r '.API_URL' "$status_file")"
export POINT23_PROBE_SERVICE_ROLE_KEY="$(jq -r '.SERVICE_ROLE_KEY' "$status_file")"
export POINT23_PROBE_ANON_KEY="$(jq -r '.ANON_KEY' "$status_file")"
export POINT23_PROBE_JWT_SECRET="$(jq -r '.JWT_SECRET' "$status_file")"

echo "POINT23 TRANSPORT PROBE: disposable local authority at ${POINT23_PROBE_SUPABASE_URL}"

deno test --allow-env --allow-net \
  contracts/point23/realtimeChannelContract.test.ts \
  contracts/point23/consumerReconnectReplayProbe.test.ts \
  contracts/point23/localSnapshotReconnectProbe.test.ts

echo 'Point23 consumer reconnect/replay probe passed.'
