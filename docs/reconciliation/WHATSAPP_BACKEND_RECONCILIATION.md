# WhatsApp Backend Reconciliation

Status: **BLOCKED BEFORE DEPLOYMENT — PRODUCTION HEALTHY**

Evidence date: 2026-07-25

Production project: `tcxvcatsqqertcnycuop`

Canonical backend repository: `oasisbaklawa2006/oasis-supabase-core`

## Facts

- Production reported `ACTIVE_HEALTHY`.
- The production migration ledger contained 168 unique versions.
- The ledger snapshot is preserved in
  `production-migration-ledger-2026-07-25.csv`.
- The seven communication-case migrations are present only as pending source
  changes in Core PR #26. They are not in the production ledger.
- Clean replay of Core's historical migrations reaches the first pending
  WhatsApp migration and then stops because
  `public.whatsapp_message_packets` is absent.
- The missing relation is part of the production schema that was never
  reconstructed in Core. Historical no-op migration files cannot recreate it.
- Supabase Support has been asked for a schema-only export and migration-ledger
  reconciliation guidance. No production write is required to answer that
  request.

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

## Required Baseline Acceptance

The schema-only artifact is acceptable only when all of these are true:

1. It contains schema objects only: no application rows, credentials, JWTs,
   storage objects, or secret values.
2. It is traceable to production project `tcxvcatsqqertcnycuop`.
3. It recreates all dependencies used by the seven pending migrations,
   including `public.whatsapp_message_packets`, `public.companies`,
   `public.sales_order_drafts`, and `public.is_whatsapp_inbox_reader(uuid)`.
4. It does not insert, delete, rename, or repair rows in
   `supabase_migrations.schema_migrations`.
5. It can build an empty local database before the seven pending migrations
   are applied.

## Decisions Prohibited Until Baseline Proof

- Do not merge PR #26.
- Do not enable Supabase GitHub production deployment or preview branching.
- Do not apply any of the seven migrations to production.
- Do not rename historical migrations to imitate production versions.
- Do not mark migrations as applied without executing and validating them.
- Do not copy Central's historical no-op migrations as a substitute for the
  schema-only baseline.

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
