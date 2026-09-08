# Point 23 — Consumer Reconnect / Replay Evidence Gate

**Scope:** Mission Control gate for Central + AI Studio consumer repos.  
**Core authority:** `contracts/point23/realtimeChannelContract.ts`, `docs/standards/POINT23_REALTIME_CHANNEL_STANDARDS.md`  
**Production baseline:** `c89c538c83eeefcd116c67f06bf86869ff63b2e3` (post-#259 main)

This document records **truthful** reconnect/replay evidence status. Core does not fabricate hosted consumer-app UI sessions or provider-driven live websocket traffic.

## What Core proves (available now)

| Obligation | Core evidence | Status |
|---|---|---|
| Scoped channel naming | `buildScopedChannelName()` + 9 deno tests | **PROVEN** |
| Snapshot-before-delta | `RealtimeConsumerSession.loadSnapshot()` guard | **PROVEN** |
| Dedupe / version handling | `classifyDeltaVersion()` + deno tests | **PROVEN** |
| Cleanup / dispose | `dispose()` + `onCleanup` hook contract | **PROVEN** |
| Unauthorized-channel denial | Allow-list + RLS pgTAP (24 assertions) | **PROVEN** |
| Realtime ≠ business truth | `POINT23_REALTIME_TRUTH_BOUNDARY` + `requiresAuthoritativeRefetch` | **PROVEN** |
| Publication authority | `realtime_subscription_contracts` + `realtime_contract_health` on production | **PROVEN** (unchanged by #258) |
| Transport reconnect/backoff | `POINT23_RECONNECT_OWNERSHIP_BOUNDARY` — Point24 consumer-owned | **BOUNDARY DECLARED** (not implemented in Core) |

## Disposable local consumer probes (Core-executable, non-fabricated)

PR #258 adds bounded executable probes that simulate Central and AI Studio consumer reconnect/replay against **disposable local fixtures** and **canonical local Supabase** (migration CI clean-replay). These do **not** substitute for hosted consumer-app UI evidence.

| Probe | Path | What it proves |
|---|---|---|
| In-process Central reconnect | `contracts/point23/consumerReconnectReplayProbe.test.ts` | Disconnect → snapshot reload → replay dedupe → new live delta |
| In-process AI Studio reconnect | same | Isolated scoped channel + reconnect dedupe on `whatsapp_operator_decisions` |
| Scope isolation | same | Central vs AI Studio channel names never collide |
| Local REST snapshot reconnect (Central) | `contracts/point23/localSnapshotReconnectProbe.test.ts` | Authoritative REST snapshot after disconnect; replay classified duplicate |
| Local REST snapshot (AI Studio) | same | AI Studio scoped channel on same Core authority |
| Local buyer denial | same | Non-team buyer cannot REST-read governed `whatsapp_inbound_messages` |

**Runner:** `bash scripts/run-point23-consumer-reconnect-probe.sh`  
**CI:** static-governance (in-process) + clean-replay (full local snapshot probes when Supabase is up)

### Local verification (2026-09-08)

| Command | Result |
|---|---|
| `deno test contracts/point23/realtimeChannelContract.test.ts` | 9 passed |
| `deno test contracts/point23/consumerReconnectReplayProbe.test.ts` | 3 passed |
| `deno test contracts/point23/localSnapshotReconnectProbe.test.ts` (local Supabase) | 3 passed |
| **Total via `run-point23-consumer-reconnect-probe.sh`** | **15 passed** |

Disposable fixture user IDs (pgTAP-aligned): team member `a0230000-0000-0000-0000-000000000003`, buyer `a0230000-0000-0000-0000-000000000002`.

## What consumers must still prove (hosted runtime gate)

Each approved consumer (`Central`, `AI Studio`) must supply **hosted-app** runtime evidence for the three governed tables:

| Consumer proof | Required behavior | Core disposable probe coverage |
|---|---|---|
| **Reconnect** | After transport disconnect, consumer re-establishes scoped channel subscription without expanding table scope | In-process fixture only — not live websocket |
| **Snapshot replay** | After reconnect, consumer reloads authoritative snapshot before applying buffered/live deltas | REST snapshot probe (local authority) |
| **Dedupe across reconnect** | Duplicate events during reconnect window do not corrupt UI state | In-process + local REST replay dedupe |
| **Cleanup** | Route unmount / logout calls `dispose()` and transport `unsubscribe()` | In-process `onCleanup` hook |
| **Unauthorized denial** | Non-team or non-consumer app cannot subscribe to governed channels | pgTAP RLS + local buyer REST denial |

### Governed subscription surface (unchanged)

- `public.whatsapp_inbound_messages`
- `public.whatsapp_operator_decisions`
- `public.whatsapp_sales_order_drafts`

## Current evidence status (honest)

| Repo | Reconnect/replay runtime evidence | Recorded by |
|---|---|---|
| **oasis-supabase-core** | Contract + disposable local probes (15 deno tests); no hosted consumer UI | This document + PR #258 |
| **Oasis-Baklawa-Central** | **NOT RECORDED** — hosted app reconnect/replay | Mission Control consumer gate |
| **oasis-ai-studio** | **NOT RECORDED** — hosted app reconnect/replay | Mission Control consumer gate |

## Explicit runtime boundaries (not fabricated)

| Boundary | Detail | Blocker type |
|---|---|---|
| **Local websocket `postgres_changes`** | Disposable probe attempted; channel reaches `SUBSCRIBED` but delivers **zero** INSERT events against canonical local Supabase even when team member can REST-read the row. Replaced with REST snapshot reconnect probe (truthful). | Local realtime delivery — not claimed |
| **Supabase Preview** | Project `tcxvcatsqqertcnycuop` — concurrent preview branch limit exhausted | **Capacity** — no preview branch available |
| **Hosted Central app** | Consumer realtime client + UI session not in Core repo | **Repo boundary** — requires `Oasis-Baklawa-Central` |
| **Hosted AI Studio app** | Consumer realtime client + UI session not in Core repo | **Repo boundary** — requires `oasis-ai-studio` |
| **Point24 transport backoff** | Exponential backoff / resubscribe retry | **Scope boundary** — consumer-owned Point24 |

No secrets, endpoints, or capacity are withheld for probes Core can run locally. Remaining gates require consumer-repo hosted runtimes or preview capacity outside Core authority.

## Point24 boundary (preserved)

Transport reconnect intervals, exponential backoff, and channel resubscribe retry logic are **Point24** scope. Core #258 explicitly does not implement or certify these. Consumers must reference `POINT23_RECONNECT_OWNERSHIP_BOUNDARY` when wiring Point24 retry policies.

## Closure readiness matrix

| Gate | Status for Point23 Core closure |
|---|---|
| Core schema / publication authority | **CLEARED** on `c89c538` (unchanged by #258) |
| Core contract tests (pgTAP + deno + static) | **CLEARED** at PR #258 HEAD |
| Core disposable consumer reconnect/replay probes | **CLEARED** — 15 tests (in-process + local REST) |
| Core CI / security scanners | **CLEARED** at PR #258 HEAD |
| Hosted Central consumer reconnect/replay | **NOT CLEARED** — consumer repo gate |
| Hosted AI Studio consumer reconnect/replay | **NOT CLEARED** — consumer repo gate |
| Independent human review | **PENDING** — draft held per STOP |

## Stop condition

`PR merged != Point23 cleared` until:

1. PR #258 merges (Core contract + disposable probe closure), **and**
2. Mission Control accepts **hosted** consumer reconnect/replay evidence from Central + AI Studio, **and**
3. Programme stage gate updated in Oasis-Baklawa-Central Mission Control.

Core #258 can be **merge-ready for Core scope** while hosted consumer runtime evidence remains a **separate downstream gate**.
