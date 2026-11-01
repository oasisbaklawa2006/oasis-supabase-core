# Core #407: scoped Product Master write authority (`can_write_product_master()`)

Migration: `20261101010000_ai_studio_product_master_write_authority.sql`.
Test: `supabase/tests/20261101010000_ai_studio_product_master_write_authority.sql` (pgTAP, 96 assertions).
Dependent: AI Studio PR #271 (draft, DO NOT MERGE before the Core release gates below).

`PR MERGED != STAGE CLEARED`. Nothing here is merged, released or applied to production by the author.

> **Historical record:** The `Defect`, `Repair`, `Authorization matrix`, `Governance note` and `Local execution evidence` sections below describe earlier pre-consolidation proposals and tests, **not** the final migration. The final, approved implementation and release state are authoritative in this summary and the trailing update.
>
> **Final scoped authority at exact head `4743e86abc267785bc73d4b9e32b3bc9b475c11b`:** `public.can_write_product_master()` preserves existing lowercase `admin`/`super_admin` rights; a legacy uppercase `SUPER_ADMIN` requires an unrevoked `public.product_master_authors` row seeded by immutable user ID **and** email for the two named owner-approved accounts only. Future `SUPER_ADMIN` holders do not inherit permission. Uppercase `ADMIN`, Product Master hard-delete, pricing and publication are unchanged. Exactly eight non-hard-delete product/media/variant policies change.
>
> **Verified CI:** manual full-schema Migration CI [41302101237](https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/41302101237) passed at `4743e86` (301 pgTAP files, 5115 tests, including 96 Core #407 assertions). Core [PR #474](https://github.com/oasisbaklawa2006/oasis-supabase-core/pull/474) was created for independent code-owner review after owner confirmation that Automatic branching is off. No new Supabase preview was observed. PR-triggered CI and independent approval govern subsequent protected release. **No production migration has been applied by this PR creation.**
>
> **Final rollback contract:** restore the eight policy predicates to `public.is_admin()`; revoke the function's EXECUTE privileges; drop `public.can_write_product_master()`; then drop `public.product_master_authors` using a separately reviewed protected rollback. Dropping the allowlist also destroys its approved-account rows, so snapshot authorization evidence before rollback. Review downstream dependencies first.

## Defect (verified read-only against production `tcxvcatsqqertcnycuop`, 2026-11-01)
* `public.users` holds 2 active uppercase `SUPER_ADMIN` rows (`admin@oasisbaklawa.com`, `purecocoa@live.in`), 3 active `super_admin`,
  0 active lowercase `admin`, 4 active uppercase `ADMIN`.
* `public.is_admin()` accepts only lowercase `admin` / `super_admin` (active). 22 public RLS policies use it.
* The nine Product Master INSERT/UPDATE/DELETE policies (3 each on `products`, `product_media`, `product_variants`) use `is_admin()`,
  so an uppercase `SUPER_ADMIN` direct write fails RLS.
* `products` SELECT is `is_internal_staff(auth.uid())`, which uppercases the role (`SUPER_ADMIN` and `ADMIN` can already read);
  media/variant SELECT is `true`. Save + read-back therefore works for legacy `SUPER_ADMIN` once the write policy passes.
* Production ledger last version `20261028055458`; this migration (`20261101010000`) is later and does not overlap any pending Core migration file.

## Repair
* New `public.can_write_product_master()` (SECURITY DEFINER, `search_path=''`, STABLE): active `users.role IN ('admin','super_admin','SUPER_ADMIN')`.
* `ALTER POLICY` on exactly **eight** named policies (INSERT/UPDATE on `products`; INSERT/UPDATE/DELETE on `product_media` and `product_variants`). The existing `products` DELETE policy continues to require `public.is_admin()`, so legacy uppercase `SUPER_ADMIN` cannot hard-delete a product.
* `public.is_admin()` untouched (source md5 asserted). Categories, the `product_variants_legacy_pre_point32` backup table, users, tv_devices,
  user_role_map and shipping-corrections policies untouched (**14** remaining `is_admin()` policies asserted).
* EXECUTE: `authenticated`, `service_role` only; `PUBLIC`/`anon` revoked.

## Authorization matrix (before -> after) for direct Product Master authoring

Product hard-delete is **not** included in the new direct-write authorization; existing canonical lowercase administrators retain their prior DELETE authority.
| Identity | Before | After |
| --- | --- | --- |
| active `admin` | allow | allow |
| active `super_admin` | allow | allow |
| active `SUPER_ADMIN` (legacy) | DENY | **allow product INSERT/UPDATE and media/variant INSERT/UPDATE/DELETE; products DELETE remains DENY** |
| active `ADMIN` (uppercase) | deny | deny |
| inactive `SUPER_ADMIN` / inactive `admin` | deny | deny |
| `owner`, `product_manager`, `catalogue_contributor` | deny | deny |
| unknown / stale / empty / missing JWT subject | deny | deny |
| `anon` | deny | deny |

Global `is_admin()` result for every row above is identical before and after.

## OWNER ENTITLEMENT DECISION — CONFIRMED 1 NOVEMBER 2026
1. **Approved for the time being:** both current active legacy uppercase `SUPER_ADMIN` users
   (`admin@oasisbaklawa.com` and `purecocoa@live.in`) may author products.
2. **Future Product Manager access:** intended only for explicitly assigned individuals; not enabled by this migration. No blanket `product_manager` access.
   Implement later as a governed per-person grant/revoke mechanism with positive/negative tests, audited approvals and protected release.
3. **Uppercase `ADMIN` remains denied**; four active users are not automatically elevated.
4. **Product hard-delete stays on the prior canonical `is_admin()` authority**, separate from day-to-day Product Master authoring.
5. **Not yet granted:** protected production migration release approval. Core CI, full-schema replay, controlled deployment, then Studio #271 and authenticated UAT still required.

**HISTORICAL — SUPERSEDED governance note:** The earlier legacy `SUPER_ADMIN` migration predicate was role-based, not pinned to two individual account IDs. At audit time only the two named active users hold that spelling. This historical exposure was resolved in the final migration by the restricted `public.product_master_authors` table. Future uppercase `SUPER_ADMIN` users are DENIED without explicit individual approval.

## Rollback
Documented in the migration header and exercised in the pgTAP test (E01-E07): re-point the eight changed policies to `is_admin()`, revoke,
`DROP FUNCTION`, then the `product_master_authors` table (with its approval records). Pure schema/authority metadata change; no data is read, rewritten or deleted. Test proves row counts unchanged, canonical admins keep
write access, legacy `SUPER_ADMIN` returns to denied. The migration must be rolled back before any later migration references the function.

## Local execution evidence (disposable PostgreSQL 16.15 + pgTAP 1.3.2, no Supabase/Docker stack)
* A faithful full replay of all 459 migrations is **not possible here**: the repo carries only a reconciliation overlay over a production
  baseline that requires the protected `materialize-production-history` path and the Supabase CLI/Docker (unavailable). 250 of 458 prior
  migrations failed on missing baseline objects, so that result was discarded.
* Instead a production-faithful reduced model (exact production `is_admin()`, `is_internal_staff`, `is_staff_role` bodies, the 22 `is_admin()`
  policy shapes, the 14 policies on the three tables, grants, NOT NULL/CHECK/UNIQUE constraints read from production) was built and the
  migration applied in a single transaction on top of it. Triggers/FKs are disabled for seeded rows (`session_replication_role=replica`); RLS is not.
* **Previous eight-policy-independent baseline:** Before narrowing product DELETE, the original nine-policy migration passed **80/80** in the reduced model. That result **does not certify the revised eight-policy migration**; rerun the revised suite and mutation checks. The earlier mutation check: 10 deliberately broken migrations (add `ADMIN`, drop `is_active`, grant to `anon`, leave one policy on
  `is_admin()`, drop `SUPER_ADMIN`, SECURITY INVOKER, no `search_path`, widen categories, widen `is_admin()`, `WITH CHECK (true)`) were each caught.
* Static governance (run locally against `origin/main`): canonical-authority, production-write-authority, production-ref-authority,
  migration-base-monotonicity, migration-governance (after adding this test; it first failed with "no SQL contract test"),
  reconciliation-ledger-freeze, repo-boundaries: pass.
* NOT executed: full-schema `supabase test db`, `supabase db lint`, protected Core CI, schema-drift gate (need CI / Supabase CLI).

## Update — durable individual authorization (head after this commit)
* `can_write_product_master()` no longer trusts the `SUPER_ADMIN` spelling. Legacy holders must have an unrevoked row in the RLS-locked
  `public.product_master_authors` (no client privilege or policy), be `is_active`, and `deleted_at IS NULL`. The migration seeds exactly
  `d505bbcf-577a-4f8d-8816-2ec080b2be15` / `admin@oasisbaklawa.com` and `27b47613-8004-46c6-9fe7-6dcc6c76bb01` / `purecocoa@live.in`
  (id AND email must match; production read-only check confirmed both are active `SUPER_ADMIN`). Future holders, revoked, soft-deleted and
  inactive holders are denied. Uppercase `ADMIN` and product hard-delete are unchanged.
* pgTAP: 96/96 on the reduced model; six new mutations (role-only SUPER_ADMIN, ignore revoked, ignore deleted, readable allowlist, drop
  is_active, add ADMIN) all caught; seeding path verified with the two production ids plus a third unapproved SUPER_ADMIN.
* Governance fix found by CI: a rollback *comment* containing a destructive-SQL keyword tripped `check-migration-governance`; reworded.
* History consolidation (owner-authorised): the unmerged branch was squashed to ONE commit on top of `main` `20708e7`; the original
  10-commit history is preserved verbatim at `backup/core-407-pre-consolidation-5366d12` and the trees are byte-identical. The migration
  is introduced once, so `check-migration-history-sequence` passes. The checker was not modified. Merge must also be a squash.
* Exact-head runner-local CI (workflow_dispatch of Migration CI; no Supabase preview branch involved) on `0b0e826`: static governance PASS,
  clean database replay PASS (migration applied after all 458 prior migrations), full pgTAP PASS: 301 files / 5115 tests, including this
  96-assertion contract (`ok`). Run 41301607763.
* **HISTORICAL — SUPERSEDED:** At the time of the original checkpoint, the Core PR had not been opened. Evidence is mixed (draft PR #413 shows "Supabase Preview:
  skipped - not associated with any Supabase Branch"; PR #399 has a preview project), and the integration setting cannot be read from here.

## 2026-11-02 release gate update

The owner confirmed Supabase Automatic branching is OFF. Core [#474](https://github.com/oasisbaklawa2006/oasis-supabase-core/pull/474) is open at reviewed source head `4743e86abc267785bc73d4b9e32b3bc9b475c11b`; the added documentation correction changes only evidence, not the migration SQL. Required check-runs were green for the prior exact SHA, but the updated PR head must be recertified. Independent code-owner approval remains mandatory. Production is unchanged until protected release.
