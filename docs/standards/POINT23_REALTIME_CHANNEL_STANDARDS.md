# Point 23 — Realtime Channel Standards

Core-owned shared standards for App-Verse Postgres Changes consumers. This document is the canonical non-migration closure for realtime-channel governance.

## Authority census (Core main)

| Artifact | Role |
|---|---|
| `public.realtime_subscription_contracts` | Allow-listed authority for Postgres Changes subscriptions |
| `public.realtime_contract_health` | Runtime verification of publication + RLS + read-policy readiness |
| `supabase_realtime` publication | Explicit table membership only (`puballtables = false`) |
| `contracts/point23/realtimeChannelContract.ts` | Shared consumer validation contract (scoped channels, snapshot-before-delta, dedupe, cleanup) |

### Approved publication surface (3 enabled contracts)

| Table | Owner | Consumers | Events | RLS read policy |
|---|---|---|---|---|
| `whatsapp_inbound_messages` | Central | Central, AI Studio | INSERT, UPDATE | `is_team_member` |
| `whatsapp_operator_decisions` | Central | Central, AI Studio | INSERT, UPDATE | `is_team_member` |
| `whatsapp_sales_order_drafts` | Central | Central, AI Studio | INSERT, UPDATE | `is_team_member` |

## Consumer obligations

### 1. Scoped channels

Channel names must follow `{consumer}:{schema}.{table}:{scope}`.

Example: `Central:public.whatsapp_inbound_messages:team-inbox`

Use `buildScopedChannelName()` from the shared contract — never invent ad-hoc channel strings.

### 2. Snapshot-before-delta

Consumers must load an authoritative snapshot (REST/RPC query under RLS) before applying any `postgres_changes` delta. The shared `RealtimeConsumerSession` rejects deltas until `loadSnapshot()` completes.

### 3. Dedupe / version handling

Track `(schema, table, rowId) → version` and treat repeated versions as duplicates. Never assume realtime delivery is exactly-once.

### 4. Cleanup

Call `dispose()` on teardown (route unmount, auth logout, feature disable). Cleanup clears dedupe state and invokes the optional `onCleanup` hook for transport unsubscribe wiring.

### 5. Unauthorized-channel denial

Subscriptions are fail-closed:

- Table must exist in `GOVERNED_REALTIME_CONTRACTS` / `realtime_subscription_contracts`
- Consumer application must be listed in `consumer_applications`
- Event type must be in the contract `event_types` (no DELETE on current surface)

### 6. Realtime is not business truth

`postgres_changes` are refresh hints only. Consumers must re-fetch authoritative state before acting. Operational/business truth remains in Postgres tables, RLS, and Point20 event-ledger flows where applicable.

## Preserved boundaries

- **Point20** — operational event ledger authority unchanged
- **Point24** — transport reconnect/backoff is consumer-owned; not implemented in this contract
- **#256 migration train** — no schema changes in Point23 closure
- **Consumer UI** — reconnect lifecycle and rendering remain in Central / AI Studio repos

## Verification

| Layer | Artifact |
|---|---|
| DB contract | `supabase/tests/20260723154050_point23_realtime_channel_contract.sql` (24 assertions) |
| Shared contract | `contracts/point23/realtimeChannelContract.test.ts` |
| Static CI | `scripts/check-realtime-channel-contract.sh` |

Local:

```bash
bash scripts/check-realtime-channel-contract.sh
deno test contracts/point23/realtimeChannelContract.test.ts
supabase test db supabase/tests/20260723154050_point23_realtime_channel_contract.sql
```

## Runtime evidence

Production runtime verification is recorded in `docs/evidence/POINT_23_REALTIME_RUNTIME_VERIFICATION.md`.

Consumer reconnect/replay gate status: `docs/evidence/POINT_23_CONSUMER_RECONNECT_REPLAY_GATE.md`.

`PR merged != Point23 cleared` until Mission Control reconciles live consumer reconnect/replay evidence in Central and AI Studio.
