# Point 23 — Exact-Head Certification (2026-09-08)

## Production baseline anchor

| Field | Value |
|---|---|
| Core main SHA | `c89c538c83eeefcd116c67f06bf86869ff63b2e3` |
| Release | Protected Production Migration Release #161 — **SUCCESS** |
| Deploy scope | #259 MACRO-TRACE-CORE (no Point23 schema delta in PR #258) |
| Production project | `tcxvcatsqqertcnycuop` |
| Prior certified base | `8beea1e` (release #159 / #256 MACRO-INVENTORY) |

Release #161 completed deployment, post-deploy ledger verification, semantic parity, and production smoke on exact SHA `c89c538`. Point23 closure remains migration-free and does not alter production schema.

## PR #258 exact-head verification (rebased onto `c89c538`)

| Field | Value |
|---|---|
| Branch | `cursor/point23-realtime-channel-closure-fe67` |
| Base | `c89c538` (current main, release #161 SUCCESS) |
| Migration SQL | **none** |

### Codacy security remediation (commit `a46b44f`)

| Field | Value |
|---|---|
| Rule | Third-party GitHub Action must be pinned to full commit SHA |
| Path | `.github/workflows/migration-ci.yml` line 143 |
| Finding | `denoland/setup-deno@v2` floating tag (annotation `101909260740`) |
| Fix | Pin to `ff4860f9d7236f320afa0f82b7e6457384805d05` |
| Mechanism | Genuine fix — not suppression |

### Static + unit contracts (local, post-rebase)

| Command | Result |
|---|---|
| `bash scripts/check-realtime-channel-contract.sh` | PASS |
| `deno test contracts/point23/realtimeChannelContract.test.ts` | 9 passed |
| `deno test contracts/point23/consumerReconnectReplayProbe.test.ts` | 3 passed |
| `bash scripts/run-point23-consumer-reconnect-probe.sh` | 15 passed (in-process + local REST snapshot) |
| `bash scripts/check-repo-boundaries.sh` | PASS |

### pgTAP behavioral contract (local canonical replay)

| Test file | Result |
|---|---|
| `supabase/tests/20260723154050_point23_realtime_channel_contract.sql` | 24 passed |

### CI at HEAD (GitHub, commit `b4a708a`) — all gates clean

| Check | Result | Notes |
|---|---|---|
| Migration CI — static governance | **SUCCESS** | Point23 static + deno |
| Migration CI — clean replay + pgTAP | **SUCCESS** | Full suite including 24 Point23 assertions |
| Repo ownership boundaries | **SUCCESS** | Backend-only boundary held |
| Codacy Static Code Analysis | **SUCCESS** | Pinned `setup-deno` SHA |
| Edge Function Governance | **Not triggered** | `contracts/point23/` |
| Supabase Preview | SKIPPED | External capacity — not functional failure |
| CodeRabbit | SUCCESS | Draft auto-skip |

## Runtime evidence (truthful, non-fabricated)

### Core production realtime authority (unchanged by #258)

From `docs/evidence/POINT_23_REALTIME_RUNTIME_VERIFICATION.md` — still valid on `c89c538` because #258 adds **tests + consumer contract only**:

- 3 enabled `realtime_subscription_contracts`
- 3 healthy `realtime_contract_health` rows
- 3 `supabase_realtime` published tables
- `puballtables = false`

No new tables published. No production mutation performed by this PR.

### Consumer reconnect/replay gate

Formal gate record: `docs/evidence/POINT_23_CONSUMER_RECONNECT_REPLAY_GATE.md`

| Evidence type | Status |
|---|---|
| Core contract obligations (scoped channels, snapshot-before-delta, dedupe, cleanup) | **PROVEN** in Core tests |
| Core publication + RLS authority | **PROVEN** (production baseline) |
| Disposable Central/AI Studio reconnect/replay (in-process + local REST) | **PROVEN** — 15 deno probes |
| Local websocket `postgres_changes` delivery | **NOT PROVEN** — SUBSCRIBED, zero events (documented) |
| Hosted Central live reconnect/replay | **NOT RECORDED** — consumer repo gate |
| Hosted AI Studio live reconnect/replay | **NOT RECORDED** — consumer repo gate |
| Supabase Preview branch | **BLOCKED** — capacity limit on `tcxvcatsqqertcnycuop` |
| Point24 transport backoff | **DECLARED** consumer-owned; not in Core #258 |

**No fabricated runtime proof.**

## Closure readiness assessment

| Scope | Ready? |
|---|---|
| **Core contract closure (PR #258 merge-ready)** | **YES** — CI green + 15 consumer probes on `c89c538` |
| **Programme Point23 cleared** | **NO** — hosted Central + AI Studio consumer runtime evidence remains open |

## Truth classification

| Dimension | Status |
|---|---|
| DOCUMENTED | yes |
| CODED | yes |
| MIGRATED | unchanged |
| TESTED | yes (pgTAP + deno + static CI) |
| DEPLOYED | unchanged |
| RUNTIME VERIFIED (Core publication) | yes |
| RUNTIME VERIFIED (consumer reconnect) | **partial** — disposable local probes only; hosted apps pending |

## Stop condition

`PR merged != Point23 cleared` until Mission Control accepts consumer reconnect/replay evidence from Central + AI Studio.
