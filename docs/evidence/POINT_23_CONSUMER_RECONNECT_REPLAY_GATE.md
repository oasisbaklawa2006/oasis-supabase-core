# Point 23 — Consumer Reconnect / Replay Evidence Gate

**Scope:** Mission Control gate for Central + AI Studio consumer repos.  
**Core authority:** `contracts/point23/realtimeChannelContract.ts`, `docs/standards/POINT23_REALTIME_CHANNEL_STANDARDS.md`  
**Production baseline:** `c89c538c83eeefcd116c67f06bf86869ff63b2e3` (post-#259 main)

This document records **truthful** reconnect/replay evidence status. Core cannot execute live consumer transport tests without fabricating provider or operator activity.

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

## What consumers must prove (Mission Control gate)

Each approved consumer (`Central`, `AI Studio`) must supply runtime evidence for the three governed tables:

| Consumer proof | Required behavior | Core can verify? |
|---|---|---|
| **Reconnect** | After transport disconnect, consumer re-establishes scoped channel subscription without expanding table scope | **No** — consumer repo only |
| **Snapshot replay** | After reconnect, consumer reloads authoritative snapshot before applying buffered/live deltas | **No** — consumer repo only |
| **Dedupe across reconnect** | Duplicate events during reconnect window do not corrupt UI state or trigger duplicate side effects | **No** — consumer repo only |
| **Cleanup** | Route unmount / logout calls `dispose()` and transport `unsubscribe()` | **No** — consumer repo only |
| **Unauthorized denial** | Non-team or non-consumer app cannot subscribe to governed channels | Partially — RLS proven in Core pgTAP; live client wiring is consumer-owned |

### Governed subscription surface (unchanged)

- `public.whatsapp_inbound_messages`
- `public.whatsapp_operator_decisions`
- `public.whatsapp_sales_order_drafts`

## Current evidence status (honest)

| Repo | Reconnect/replay runtime evidence | Recorded by |
|---|---|---|
| **oasis-supabase-core** | Contract + tests only; no live Supabase Realtime client session | This document + PR #258 |
| **Oasis-Baklawa-Central** | **NOT RECORDED** in Core | Mission Control consumer gate |
| **oasis-ai-studio** | **NOT RECORDED** in Core | Mission Control consumer gate |

**No fabricated runtime proof.** Core does not host Central/AI Studio realtime client code and cannot truthfully claim consumer reconnect behavior without live consumer-repo evidence.

## Point24 boundary (preserved)

Transport reconnect intervals, exponential backoff, and channel resubscribe retry logic are **Point24** scope. Core #258 explicitly does not implement or certify these. Consumers must reference `POINT23_RECONNECT_OWNERSHIP_BOUNDARY` when wiring Point24 retry policies.

## Closure readiness matrix

| Gate | Status for Point23 Core closure |
|---|---|
| Core schema / publication authority | **CLEARED** on `8beea1e`+ (unchanged by #258) |
| Core contract tests (pgTAP + deno + static) | **CLEARED** at PR #258 HEAD |
| Core CI / security scanners | **CLEARED** at PR #258 HEAD (`848ce00`+) |
| Consumer reconnect/replay runtime | **NOT CLEARED** — requires Central + AI Studio evidence |
| Independent human review | **PENDING** — after exact-head rebase onto post-#161 main |

## Stop condition

`PR merged != Point23 cleared` until:

1. PR #258 merges (Core contract closure), **and**
2. Mission Control accepts consumer reconnect/replay evidence from Central + AI Studio, **and**
3. Programme stage gate updated in Oasis-Baklawa-Central Mission Control.

Core #258 can be **merge-ready for Core scope** while consumer runtime evidence remains a **separate downstream gate**.
