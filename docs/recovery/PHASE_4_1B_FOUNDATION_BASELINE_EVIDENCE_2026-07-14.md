# Phase 4.1b Foundation Baseline — Evidence Document — 2026-07-14

**Status:** Draft migration + static validation only. Not applied to any
database. No PR, merge, deploy, Supabase branch, or Supabase project was
created. No RLS, policy, grant, function, Edge Function, storage, WhatsApp,
approval RPC, SKU data, product data, or application code was touched.

This document supports:
`supabase/migrations/20260101000000_foundation_baseline_categories_companies_users_products_orders_order_items.sql`
and
`scripts/validate-foundation-baseline.py`.

---

## 1. Live-source capture method and timestamp

All structural facts in the migration (columns, types, defaults,
nullability, primary keys, unique constraints, foreign keys, CHECK
constraints, non-constraint indexes) were captured via **read-only**
`SELECT` queries against production project `tcxvcatsqqertcnycuop`, executed
2026-07-14, using:

- `information_schema.columns` — column name, `data_type`, `udt_name`,
  `is_nullable`, `column_default`, `ordinal_position` — for `categories`,
  `companies`, `users`, `orders`, `order_items`, and `products` (137 rows).
- `information_schema.table_constraints` joined to `key_column_usage` and
  `constraint_column_usage` — full FK graph for the six-table set, which is
  what surfaced the `companies.account_manager_id -> users.id` /
  `users.company_id -> companies.id` circular dependency.
- `pg_constraint` + `pg_get_constraintdef()` — exact PK/UNIQUE/CHECK
  constraint definitions, including the two independently-defined
  `companies` credit-limit CHECK constraints noted in §2.
- `pg_indexes` — indexes not already implied by a PK/UNIQUE constraint
  (e.g. `idx_companies_is_frozen`, `orders_wamid_unique_idx`).

The 137-column `products` result was saved verbatim to a local JSON capture
and converted to SQL column definitions by a small script
(`information_schema` type name -> Postgres DDL type, including array
handling for `_text` -> `text[]`), specifically so the column list did not
need to be hand-transcribed from memory or prose, per the task's hard
constraint.

No `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, or `DROP` statement was
ever sent to `tcxvcatsqqertcnycuop` in this phase.

## 2. Deviations from live production

Two are documented; both were preserved faithfully rather than "corrected,"
since the task explicitly asks for evidence-based capture, not editorial
cleanup:

1. **`companies` has two overlapping CHECK constraints on `credit_limit`**:
   `companies_credit_limit_nonneg CHECK ((credit_limit IS NULL) OR
   (credit_limit >= 0))` and `companies_credit_limit_non_negative CHECK
   (credit_limit >= 0)`. This is genuine drift in live production (two
   constraints doing overlapping work, likely from an earlier migration that
   was never cleaned up), not an artifact of this capture. Both are
   reproduced in the baseline migration unchanged, because inventing a
   "fix" here would make the migration diverge from what production
   actually enforces today.
2. **This repo's `supabase/config.toml` declares `project_id =
   "wgajrxyoararisiwjzox"`**, which does **not** match
   `tcxvcatsqqertcnycuop`, the production project used for every
   introspection query in this engagement (Phases 0–4.1a, and this phase).
   This is a pre-existing configuration mismatch discovered while working
   in this repo for Phase 4.1b — it was not introduced by this change, and
   this migration does not touch `config.toml`. It is called out here
   because it directly affects the disposable-branch replay test described
   in §5: any `supabase db branch create` / `supabase link` invoked from
   this repo as-is would target `wgajrxyoararisiwjzox`, not the production
   project this baseline was captured from, unless corrected or overridden
   first. Resolving that mismatch is out of scope for this phase (it is a
   config/ownership question, not a schema question) and is called out as
   an unresolved structural gap in the final report.

No other deviations were introduced. Column order, defaults, nullability,
and constraint definitions match live production exactly for all six
tables.

## 3. Intentionally excluded objects

Excluded by the task's hard safety constraints and by this migration's
declared scope (structural prerequisite only):

- RLS policies, `ALTER ... ENABLE ROW LEVEL SECURITY`, grants/revokes on any
  of the six tables.
- Triggers and functions (including `approve_catalogue_draft_internal`,
  already captured in Phase 3b but not part of this baseline).
- Edge Functions, storage buckets/policies, WhatsApp integration objects.
- The other ~149 tables that exist in production outside this six-table
  set (this baseline is scoped exactly to `categories`, `companies`,
  `users`, `products`, `orders`, `order_items` — the minimal set the
  existing tracked migration lineage assumes already exists).
- `catalogue_ai_studio_drafts` / `catalogue_ai_studio_draft_audit_log` and
  any other catalogue-AI-Studio object (owned by a later phase per the
  Phase 3b package breakdown, not this one).
- PR06C1b packaging-scalar work.
- Seed data, backfills, or any `INSERT` — every table this migration
  creates is empty on creation.
- SKU dedup/uniqueness work and EXECUTE-grant narrowing (both explicitly
  out of scope per the task instructions).

## 4. Why this migration is safe to review but has not been applied

- Every `CREATE TABLE` uses `IF NOT EXISTS`; every `CREATE INDEX` uses
  `IF NOT EXISTS`; the one deferred `ALTER TABLE ... ADD CONSTRAINT` (the
  circular `companies.account_manager_id -> users.id` FK) is wrapped in a
  `DO $$ ... IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname =
  ...) THEN ... END IF; END $$;` guard — so applying it twice, or applying
  it against a database that already has some of these tables from another
  source, is a no-op rather than an error.
- It contains zero `DROP`, `TRUNCATE`, `DELETE`, `INSERT`, `UPDATE`,
  `GRANT`, `REVOKE`, `CREATE POLICY`, `CREATE FUNCTION`, or `CREATE
  TRIGGER` statements — confirmed both by manual review and by the
  automated static check (`scripts/validate-foundation-baseline.py`,
  check 4/5).
- It has not been run against `tcxvcatsqqertcnycuop` (which already has
  these six tables and would simply no-op on the `CREATE TABLE IF NOT
  EXISTS` statements) or against any other database, disposable branch, or
  local Postgres instance. **No live replay of any kind has occurred.**
  The validation performed in this phase is exclusively static text
  parsing of the `.sql` file — see §5 and the "Verification" section of
  the final report for the actual command run and its output.
- Because no live replay occurred, this migration has not been proven to
  apply cleanly against a truly empty Postgres schema — only that its
  *text* satisfies the structural/ordering/idempotency/safety properties a
  reviewer can check without a database. That is the isolated replay gap
  called out next.

## 5. Exact isolated replay test still required before merge

Before this migration is merged or treated as authoritative, run, in a
**disposable** environment only (see the final report for the cost/
permission this needs and why it was not done in this phase):

1. Create a disposable Supabase branch or a local ephemeral Postgres
   instance seeded with only the `pgcrypto` extension (for
   `gen_random_uuid()`) and the built-in `auth` schema's `users` table
   (empty is fine — only the relation needs to exist, for
   `orders_closed_by_fkey` / `orders_finance_verified_by_fkey`).
2. Apply this migration standalone against that empty schema and confirm
   zero errors, in particular no `relation "..." does not exist` /
   `constraint "..." referenced table does not exist` errors, across all 7
   steps (categories, companies, users, deferred ALTER, products, orders,
   order_items).
3. Apply it a second time and confirm it is a true no-op (idempotency),
   consistent with the guards described in §4.
4. Apply Central's earliest tracked migration
   (`20260316122451_bbadbd7b-9e37-467f-b174-96232c0c4fe7.sql`) immediately
   after, and confirm its `CREATE POLICY ... ON public.orders ...` no
   longer fails with a missing-relation error for `public.orders` or
   `public.users`.
5. Confirm the disposable branch/instance targets a project consistent with
   this capture (or is a from-scratch local instance) — not silently
   pointed at `wgajrxyoararisiwjzox` via this repo's current
   `supabase/config.toml`, per the deviation noted in §2.

None of steps 1–5 were performed in this phase: this phase is
draft-and-static-validation only, per the task's explicit instruction, and
creating a Supabase branch/database requires separate cost approval that
was not sought or granted here.
