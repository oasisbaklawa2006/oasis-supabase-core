# WhatsApp Backend Reconciliation

Status: **REPLAY PROVEN — PREVIEW UAT AND DEPLOYMENT STILL BLOCKED**

Evidence date: 2026-07-27

Production project: `tcxvcatsqqertcnycuop`

Canonical backend repository: `oasisbaklawa2006/oasis-supabase-core`

## Facts

- Production reported `ACTIVE_HEALTHY`.
- The production migration ledger contained 168 unique versions.
- The ledger snapshot is preserved in
  `production-migration-ledger-2026-07-25.csv`.
- A direct Supabase CLI schema-only dump was received on 2026-07-27.
- The uploaded artifact checksum is
  `c1d3b4bd7ec0f96431e06eba19cd6aab879edbe3fa89cb2ecdc756bd84f2cebb`.
- The LF-normalized, checksum-locked baseline is
  `supabase/migrations/20260723161256_legacy_role_authority_baseline.sql`
  with checksum
  `2b7df9c40a556b6be5e8b6cb37c4a028f31fa931cf11f5d34595151dbcbbc3ca`.
- The baseline contains 196 tables, 99 functions, 424 public-schema policies,
  and 15 production-verified Storage policies, with no row-copy statements,
  passwords, tokens, connection strings, or API keys.
- A checksum-locked seed restores 38 non-sensitive infrastructure/reference
  rows only. Production Cron commands were excluded because two of three
  command bodies matched a secret-bearing heuristic.
- All 168 production versions now have an exact local version counterpart.
  Earlier versions are auditable no-op compatibility stubs; the final applied
  version carries the squashed production schema. Production migration history
  was not edited.
- The 41 superseded Core migrations whose timestamps never matched production
  are preserved under
  `supabase/archived-migrations/pre-production-baseline-20260727/`.
- The seven communication-case migrations are present only as pending source
  changes in Core PR #26. They are not in the production ledger.
- The prior missing dependencies now exist in the baseline, including
  `public.whatsapp_message_packets`, `public.companies`,
  `public.sales_order_drafts`, and
  `public.is_whatsapp_inbox_reader(uuid)`.
- GitHub Actions run
  [`30221700997`](https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/30221700997)
  passed zero-state replay, every database contract, and database lint at
  commit `c597686f9e619f88f4b0ee81a2e706e51de25c7d`.
- A read-only Supabase security-advisor check confirmed pre-existing production
  findings, including 13 security-definer views. Those findings are not caused
  by the baseline and require a separately approved remediation tranche.

## Pending WhatsApp Order

| Order | Version | Purpose | Production |
|---:|---|---|---|
| 1 | `20260725150000` | Canonical communication-case foundation | Unapplied |
| 2 | `20260725173000` | Accountability and handoffs | Unapplied |
| 3 | `20260725180000` | Formal clarification | Unapplied |
| 4 | `20260725200000` | Outbound governance | Unapplied |
| 5 | `20260725210000` | Lifecycle, consent, closure | Unapplied |
| 6 | `20260725220000` | Sensitive intake and manual queues | Unapplied |
| 7 | `20260725230000` | Reconciliation and legacy retirement | Unapplied |

## Baseline Acceptance

All baseline intake requirements passed:

1. It contains schema objects only: no application rows, credentials, JWTs,
   storage objects, or secret values.
2. It is traceable to production project `tcxvcatsqqertcnycuop`.
3. It recreates all dependencies used by the seven pending migrations,
   including `public.whatsapp_message_packets`, `public.companies`,
   `public.sales_order_drafts`, and `public.is_whatsapp_inbox_reader(uuid)`.
4. It does not insert, delete, rename, or repair rows in
   `supabase_migrations.schema_migrations`.
5. It builds an empty isolated database before the seven pending migrations
   are applied; the complete replay and contract suite passed in GitHub CI.

## Decisions Prohibited Until Preview UAT and Final Approval

- Do not merge PR #26.
- Do not enable Supabase GitHub production deployment or preview branching.
- Do not apply any of the seven migrations to production.
- Do not modify or repair production migration history.
- Do not mark migrations as applied without executing and validating them.
- Do not modify the checksum-locked baseline outside a new reconciliation
  review.

## Completion Evidence

This reconciliation becomes `GO` only when the runbook in
`docs/runbooks/WHATSAPP_DATABASE_RELEASE.md` records:

- baseline provenance and checksum;
- zero-state local replay;
- pgTAP and database lint;
- isolated preview replay;
- rollback-only behavioral UAT;
- schema drift review;
- production backup and rollback owner;
- explicit final production GO approval.
