# Point 23 — Deadline reconciliation (2026-09-28)

## Core main anchor

| Field | Value |
|---|---|
| Protected Core main | `825caf99eda1974afbb73ae362a5650829d71afa` |
| PR #258 branch | `cursor/point23-realtime-channel-closure-fe67` |
| Prior stale evidence bases | `c89c538`, `1503d6c` — superseded by this reconciliation |

## Is Point23 still required for launch / Point100?

| Question | Evidence-backed answer |
|---|---|
| Does main already ship the shared consumer contract? | **NO** — `contracts/point23/realtimeChannelContract.ts` exists only on #258; `origin/main` has DB governance (`realtime_subscription_contracts`) from #20 but no Core consumer session contract + probes |
| Did later WhatsApp / realtime work supersede Point23? | **NO** — post-#260/#288 main adds defect ledger, drift-watch, catalogue source RPCs; **no** replacement for scoped-channel + snapshot-before-delta + dedupe consumer standards |
| Point100 coupling | Point100 blockers on Core (e.g. E-way status) are unrelated; WhatsApp inbox realtime consumer standards remain an open programme gate documented in `POINT_23_CONSUMER_RECONNECT_REPLAY_GATE.md` |
| Verdict | **STILL REQUIRED** for Core contract closure — not deferred/superseded |

## Mergeability reconciliation

| Issue | Resolution |
|---|---|
| GitHub `mergeStateStatus: DIRTY` at `9362b76` | Merged `origin/main` (`825caf9`) into branch; resolved `migration-ci.yml` to retain main drift-watch + WhatsApp readiness **and** Point23 deno/probes |
| Migration SQL | **None** on #258 diff vs `825caf9` |

## CodeRabbit remediation (this reconciliation)

| Finding | Fix |
|---|---|
| AI Studio snapshot uses service-role insert only | Load snapshot via authenticated `teamClient` REST under RLS |
| `applyDelta` foreign table/schema | Reject with `rejected_unauthorized_event` when event schema/table ≠ session contract |
| Monotonic replay (`v2 → v1 → v2`) | `compareMonotonicVersions` + stale versions classified duplicate |
| pgTAP consumer set | Added `<@` exact-set check alongside `@>` |
| Probe status file | `mktemp` + EXIT trap instead of fixed `/tmp` path |
| Static check | Executable greps for owner/consumers/eventTypes + new deno regression names |

## Hosted consumer runtime (unchanged — not fabricated)

| Consumer | Status |
|---|---|
| Hosted Central reconnect/replay | **NOT RECORDED** — realtime kill-switch; Point23 tables not direct postgres_changes consumer in Central census |
| Hosted AI Studio reconnect/replay | **NOT RECORDED** — consumer repo runtime; Core agent lacks hosted session credentials |
| Local/production websocket events | **NOT CLAIMED** — zero events without governed write surface |

## Stop condition

- **Core PR #258:** merge-ready pending exact-head CI on new SHA after push
- **Programme Point23 cleared:** **NO** until hosted consumer evidence accepted in Mission Control
- **No production mutation** performed in this reconciliation
