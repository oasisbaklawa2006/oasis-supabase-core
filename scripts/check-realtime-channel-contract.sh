#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

contract='contracts/point23/realtimeChannelContract.ts'
test_file='contracts/point23/realtimeChannelContract.test.ts'
consumer_fixture='contracts/point23/disposableConsumerFixture.ts'
consumer_probe_test='contracts/point23/consumerReconnectReplayProbe.test.ts'
local_snapshot_probe='contracts/point23/localSnapshotReconnectProbe.test.ts'
consumer_probe_script='scripts/run-point23-consumer-reconnect-probe.sh'
pgtap='supabase/tests/20260723154050_point23_realtime_channel_contract.sql'

for file in "$contract" "$test_file" "$consumer_fixture" "$consumer_probe_test" \
  "$local_snapshot_probe" "$consumer_probe_script" "$pgtap"; do
  [[ -f "$file" ]] || { echo "REALTIME CHANNEL CONTRACT VIOLATION: missing $file" >&2; exit 1; }
done

grep -Fq 'export const GOVERNED_REALTIME_CONTRACTS' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: governed allow-list missing' >&2; exit 1; }
grep -Fq 'export const POINT23_REALTIME_TRUTH_BOUNDARY' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: truth boundary constant missing' >&2; exit 1; }
grep -Fq 'export const POINT23_RECONNECT_OWNERSHIP_BOUNDARY' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: reconnect ownership boundary missing' >&2; exit 1; }
grep -Fq 'buildScopedChannelName' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: scoped channel builder missing' >&2; exit 1; }
grep -Fq 'assertAuthorizedRealtimeSubscription' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: unauthorized-channel denial missing' >&2; exit 1; }
grep -Fq 'class SnapshotBeforeDeltaViolation' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: snapshot-before-delta guard missing' >&2; exit 1; }
grep -Fq 'class RealtimeConsumerSession' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: consumer session lifecycle missing' >&2; exit 1; }
grep -Fq 'whatsapp_inbound_messages' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: whatsapp_inbound_messages contract drifted' >&2; exit 1; }
grep -Fq 'whatsapp_operator_decisions' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: whatsapp_operator_decisions contract drifted' >&2; exit 1; }
grep -Fq 'whatsapp_sales_order_drafts' "$contract" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: whatsapp_sales_order_drafts contract drifted' >&2; exit 1; }

grep -Fq 'unauthorized-channel denial rejects uncontracted tables' "$test_file" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: unauthorized-table regression test missing' >&2; exit 1; }
grep -Fq 'snapshot-before-delta rejects deltas before authoritative snapshot load' "$test_file" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: snapshot-before-delta regression test missing' >&2; exit 1; }
grep -Fq 'dedupe and version handling ignores duplicate row versions' "$test_file" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: dedupe regression test missing' >&2; exit 1; }
grep -Fq 'cleanup disposes session and blocks further deltas' "$test_file" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: cleanup regression test missing' >&2; exit 1; }
grep -Fq 'realtime-not-business-truth boundary requires authoritative refetch' "$test_file" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: truth-boundary regression test missing' >&2; exit 1; }

grep -Fq 'runDisposableConsumerReconnectReplayProbe' "$consumer_fixture" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: disposable consumer reconnect fixture missing' >&2; exit 1; }
grep -Fq 'Central disposable fixture reconnect reloads snapshot and dedupes replay' "$consumer_probe_test" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: Central consumer reconnect probe missing' >&2; exit 1; }
grep -Fq 'AI Studio disposable fixture reconnect reloads snapshot and dedupes replay' "$consumer_probe_test" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: AI Studio consumer reconnect probe missing' >&2; exit 1; }
grep -Fq 'local snapshot reconnect probe: Central reloads authoritative REST snapshot' "$local_snapshot_probe" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: local REST snapshot reconnect probe missing' >&2; exit 1; }
grep -Fq 'non-team buyer cannot load authoritative snapshot' "$local_snapshot_probe" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: buyer denial snapshot probe missing' >&2; exit 1; }

grep -Fq 'select plan(24);' "$pgtap" \
  || { echo 'REALTIME CHANNEL CONTRACT VIOLATION: pgTAP plan count drifted' >&2; exit 1; }

echo 'Realtime channel contract check passed.'
