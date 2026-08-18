# Production migration lineage recovery — 2026-08-18

## Environment identity (resolved)

`tcxvcatsqqertcnycuop` ("oasis-baklawa") is the **sole production Supabase
project** in this organization. There is no separate staging project.
`docs/runbooks/CONTROLLED_SUPABASE_PRODUCTION_RELEASE.md` names this ref as
PRODUCTION explicitly, and Central's shipped client code hardcodes the same
ref (`SupportChat.tsx:69`). Any prior PR description or workflow name that
called this ref "staging" reflected a good-faith but incorrect belief that
this database had a separate non-production mode. That belief is retired by
this recovery (see "False-staging workflow retirement" below).

## What broke

`Production Migration Release`'s automatic read-only preflight job was
failing on every push to `main` because the production ledger
(`supabase_migrations.schema_migrations`) contained 17 applied versions with
no corresponding entry anywhere in Core's committed migration history or
reconciliation ledgers — an `unaccounted_remote` failure per
`scripts/verify-production-migration-ledger.sh`. This blocked deployment of
9 already-merged RGS/Production governance migrations
(`20260817090000`-`20260817160000`), even though those migrations are
correct and unrelated to the WhatsApp divergence.

## Root cause

Both open Core PR #82 (`fix/wa-multimodal-hindi-interpretation`) and PR #84
(`feat/wa-b2b-case-orchestration-closure`) applied their migrations directly
against `tcxvcatsqqertcnycuop`, generating fresh timestamps at apply-time,
in the belief that this was a safe "staging" action separate from a later
"real" production deployment. `.github/workflows/step1-staging-certification.yml`
encoded and reinforced the same misunderstanding: it ran a raw `psql -f`
migration loop and `scripts/step1-certification/run.mjs` test-data writes
directly against the same live database, entirely outside the governed
`Production Migration Release` gate. 17 of those directly-applied versions
(16 WhatsApp + `wa_atomic_packet_authority`) never had a matching committed
file under their applied timestamp.

## Evidence — all 17 unaccounted-remote versions traced to real source

Every one of the 17 was traced to a real, reviewable candidate in an open
Core PR branch (not name-only — confirmed via `pg_get_functiondef()` /
catalog diff against the applied SQL, and normalized-SHA / line-by-line diff
against the PR candidate file). Full row-by-row evidence, including PR
number, branch, head SHA, file path, and diff method, is recorded in
[`production-migration-ledger-remote-history-2026-08-18.csv`](./production-migration-ledger-remote-history-2026-08-18.csv).
None are genuinely lost or unsourced. Classification:

- 1 version (`20260816125809`, representing `wa_atomic_packet_authority`) is
  already fully represented on `main` (`20260816120000_wa_atomic_packet_authority.sql`,
  byte-identical modulo one non-functional comment) — no action needed.
- 16 versions (the WhatsApp PR #82/#84 candidates) are genuinely absent from
  `main` and require forward-only replacement migrations once their source
  PRs are ready to merge — tracked as `pending_forward` rows in
  [`canonical-production-lineage-2026-08-18.csv`](./canonical-production-lineage-2026-08-18.csv)
  where they overlap with the 9 RGS/WA-index gaps this PR closes now (10 of
  the 17 total gaps — the `20260816120100` unique index plus the 9
  RGS/production-authority migrations — ship as forward-replacement files in
  this PR; the remaining WhatsApp-specific gaps stay open pending PR #82/#84's
  own merge readiness and are represented in the remote-history ledger so
  the preflight no longer fails on them).

## Correction: recovered historical migrations required (not just forward-only ones)

The first version of this PR shipped only the 10 forward-only replacement
migrations below and updated the two reconciliation ledgers, but did **not**
add local migration files for the 16 WhatsApp versions that are genuinely
absent from `main` (it only documented them as `parallel-staging-lineage`
remote-history rows). CI's `Clean database replay and pgTAP contracts` job
failed as a result: `supabase start` performs the zero-state migration
replay as part of its own bootstrap, and it failed with
`relation "public.whatsapp_packet_ai_interpretations" does not exist`
(SQLSTATE `42P01`) applying `20260817213000_fwd_wa_packet_ai_release_hardening_delta.sql`,
because that table is only created by production's `20260817114750`
migration, which had no committed Core file at all. Production has the
table (it was applied directly, out-of-band, which is exactly the incident
this recovery exists to close); a zero-state Core replay does not.

The fix ships 16 new migration files under their **actual production
version numbers** (not the later PR #82/#84 authoring timestamps), each
reproducing the semantics already live in production -- 4 confirmed via a
direct read-only re-fetch of `pg_get_functiondef`/table DDL against the
live catalog for this PR, the remaining 12 sourced from the PR #82/#84
candidate files already diff-verified byte-for-byte-modulo-comments against
the applied SQL in the prior reconciliation session (see the remote-history
CSV's git history for that evidence; those 16 rows have been removed from
the CSV now that Core carries the actual files). This makes the recovered
historical lineage, not just the forward-only gap, replay cleanly from
zero -- matching what production actually has at every step, in the same
order production received it.

The remote-history reconciliation CSV's unique-version count dropped from
49 to 33 as a result (the 16 recovered versions are no longer "remote-only"
-- they're represented by real local files at their real versions). The
canonical-lineage CSV is unchanged at 26, since these 16 recovered files
are present in both local and remote and therefore never appear in
`local_missing_versions`.

## Forward-only replacement migrations in this PR

10 new migrations, each timestamped above the current production max
(`20260817211610`) and below the existing six-TV correction
(`20260818090000`, already on `main` via PR #88), reproduce the semantics of
9 already-merged-but-undeployed RGS/production-authority migrations plus the
one still-open WA provider-message unique index, so they deploy cleanly
without rewriting history on the originals:

| New file | Reproduces |
|---|---|
| `20260817212000_fwd_wa_provider_message_unique_index.sql` | `20260816120100_wa_provider_message_unique_index.sql` |
| `20260817213000_fwd_wa_packet_ai_release_hardening_delta.sql` | Genuine delta from PR #82's `20260817140400_whatsapp_packet_ai_release_hardening.sql`: drops the still-live default on `whatsapp_packet_ai_interpretations.provider_message_ids`, and replaces `complete_whatsapp_media_processing()` with the idempotent-replay-guarded + packet-row-locked version (confirmed missing from the live function via `pg_get_functiondef()`). The table grant/revoke half of that PR file is intentionally **not** re-applied — confirmed already live via `information_schema.role_table_grants`. |
| `20260817214000_fwd_rgs_department_taxonomy.sql` | `20260817090000_rgs_department_taxonomy.sql` |
| `20260817215000_fwd_rgs_production_governed_authority.sql` | `20260817100000_rgs_production_governed_authority.sql` |
| `20260817220000_fwd_rgs_production_lifecycle_completion.sql` | `20260817110000_rgs_production_lifecycle_completion.sql` |
| `20260817221000_fwd_rgs_production_intake_rpcs.sql` | `20260817120000_rgs_production_intake_rpcs.sql` |
| `20260817222000_fwd_rgs_quick_log_production_rpc.sql` | `20260817130000_rgs_quick_log_production_rpc.sql` |
| `20260817223000_fwd_rgs_department_execution_metadata.sql` | `20260817140000_rgs_department_execution_metadata.sql` |
| `20260817224000_fwd_rgs_authority_hardening.sql` | `20260817150000_rgs_authority_hardening.sql` |
| `20260817225000_fwd_rgs_demand_source_linkage.sql` | `20260817160000_rgs_demand_source_linkage.sql` |

No known defect was forward-ported: the release-hardening delta was
re-derived from a direct live-catalog comparison (not assumed), confirming
exactly two genuine gaps (dropped default, replay/lock guard) versus one
already-applied gap (table grants).

## False-staging workflow retirement

`.github/workflows/step1-staging-certification.yml` is retired (fails
closed on `workflow_dispatch`, `pull_request` trigger removed) rather than
deleted, preserving its run history for audit. Its header now documents why:
it ran two production-write paths outside the governed release gate against
`tcxvcatsqqertcnycuop`, which is production, not a separate staging project.

## Verifier and regression fixture updates

- `scripts/verify-production-migration-ledger.sh` now points at the
  2026-08-18 ledgers by default and parameterizes its exact-count checks
  (`EXPECTED_REMOTE_HISTORY_COUNT=49`, `EXPECTED_CANONICAL_LINEAGE_COUNT=26`)
  instead of hardcoding the prior 32/16 counts.
- `scripts/tests/verify-production-migration-ledger-regression.sh` now
  passes its own matching 32/16 expected counts explicitly, so its synthetic
  fixture keeps exercising the exact-match tripwire independent of the real
  production ledger's growth.
- Both scripts were re-verified locally after every change in this PR; see
  validation summary below.

## Validation performed

- `bash scripts/check-migration-governance.sh` — PASS (265 migration files
  inventoried, 26 changed migrations hardened, 0 violations).
- `bash scripts/tests/verify-production-migration-ledger-regression.sh` —
  PASS.
- `scripts/verify-production-migration-ledger.sh` simulated against a live
  snapshot of `supabase_migrations.schema_migrations` (261 versions, fetched
  read-only via SQL queries, max version `20260817211610`) — **Status:
  SUCCESS**, local migration count 265, remote-history reconciliation count
  33, canonical-lineage reconciliation count 26, all 10 forward-replacement
  migrations plus the pre-existing six-TV correction correctly classified as
  pending append-only, zero unaccounted-remote versions.
- Live read-only catalog checks confirming the release-hardening delta's
  scope: `pg_get_functiondef` on `complete_whatsapp_media_processing`,
  `information_schema.columns` on `whatsapp_packet_ai_interpretations.provider_message_ids`,
  `information_schema.role_table_grants` on the same table.
- Live read-only catalog checks confirming the historical recovery: exact
  applied SQL fetched for versions `20260817114750`, `20260817115224`,
  `20260817120220`, `20260817123608`, `20260817181608` via the production
  migration ledger's statements column; the remaining 11 recovered files
  reuse PR #82/#84 candidate content already diff-verified against the
  applied SQL in the prior reconciliation session.
- CI: `Clean database replay and pgTAP contracts` now passes fully on this
  PR (confirmed green on commit `5be2124`, run `32176672129`) — the full
  zero-state replay of all 265 migrations succeeds, including every
  recovered historical file and forward-only replacement, and the pgTAP
  suite passes. This was reached only after two further real bugs
  surfaced by the replay itself were fixed: unguarded `CREATE POLICY`/
  `ADD CONSTRAINT` statements in two forward-replacement files that
  collided with their already-applied originals during replay, and a bare
  `CREATE FUNCTION` (vs. `CREATE OR REPLACE FUNCTION`) for
  `reserve_rgs_stock` that collided the same way.

## Pre-existing production bugs surfaced by review (not fixed in this PR)

CodeRabbit's review of the recovered historical migrations found several
genuine defects that are already live in production today (confirmed by
re-checking the actual applied SQL, the same method used throughout this
recovery): a `disclosure_scope` NULL-containment gap that can bypass an
outbound-reply authority check, a missing `revoke`/`grant` pair on
`whatsapp_release_case_reply` (defense-in-depth gap only — internal
`auth.uid()`/permission checks still block effects), a replay guard on
`inventory_reservations`/`production_rgs_transfers` movements that isn't
scoped to its own movement type, a missing unique constraint on
`inventory_reservations.correlation_id` that leaves a narrow concurrent
double-reservation window, `quick_log_production_to_rgs` computing
`assigned_qty` in a way that can spuriously fail the wastage tolerance
check, a `pause` RPC that doesn't explicitly reject a NULL reason, an
approval-timestamp comparison that drops timezone information, and a
`pgcrypto` digest call missing its `extensions.` schema qualifier.

None of these are introduced by this recovery — they are reproduced
byte-for-byte (or functionally identically) from what is already applied to
`tcxvcatsqqertcnycuop`, which is the explicit point of a lineage-recovery
file: the recovered migrations must match production exactly, not a
corrected version of it. Fixing them here would make the recovered history
diverge from production's actual applied bytes. Each is confirmed and
replied to on its PR review thread as a legitimate follow-up, to be
addressed in dedicated forward-only migrations outside this PR's scope
(migration-lineage recovery only).

## Known visibility limitation: Codacy findings

Codacy Static Code Analysis reported 2 new medium "Compatibility" issues
(`action_required`) on an earlier revision of this PR. Their content could
not be retrieved from this environment: both `app.codacy.com` and
`api.codacy.com` are blocked by this session's network egress policy, and
the GitHub check-run output for this check carries only a count/severity
summary with no line-level annotations. **EXTERNAL REVIEW VISIBILITY
BLOCKER — Codacy finding body inaccessible.** This is recorded rather than
guessed at; resolving it requires either dashboard access from a session
with egress to `app.codacy.com`, or the findings being surfaced through
another accessible channel (e.g. a PR review comment).

No production write of any kind was performed. No migration repair, no
manual `schema_migrations` mutation, no direct production SQL migration
execution.
