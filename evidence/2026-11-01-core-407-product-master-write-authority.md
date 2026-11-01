# Core #407: scoped Product Master write authority (`can_write_product_master()`)

Migration: `20261101010000_ai_studio_product_master_write_authority.sql`.
Test: `supabase/tests/20261101010000_ai_studio_product_master_write_authority.sql` (pgTAP, 80 assertions).
Dependent: AI Studio PR #271 (draft, DO NOT MERGE before the Core release gates below).

`PR MERGED != STAGE CLEARED`. Nothing here is merged, released or applied to production by the author.

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
* `ALTER POLICY` on exactly the nine named policies (names, commands, role targets, SELECT policies unchanged).
* `public.is_admin()` untouched (source md5 asserted). Categories, the `product_variants_legacy_pre_point32` backup table, users, tv_devices,
  user_role_map and shipping-corrections policies untouched (13 remaining `is_admin()` policies asserted).
* EXECUTE: `authenticated`, `service_role` only; `PUBLIC`/`anon` revoked.

## Authorization matrix (before -> after) for direct Product Master INSERT/UPDATE/DELETE
| Identity | Before | After |
| --- | --- | --- |
| active `admin` | allow | allow |
| active `super_admin` | allow | allow |
| active `SUPER_ADMIN` (legacy) | DENY | **allow (product/media/variant only)** |
| active `ADMIN` (uppercase) | deny | deny |
| inactive `SUPER_ADMIN` / inactive `admin` | deny | deny |
| `owner`, `product_manager`, `catalogue_contributor` | deny | deny |
| unknown / stale / empty / missing JWT subject | deny | deny |
| `anon` | deny | deny |
Global `is_admin()` result for every row above is identical before and after.

## OWNER APPROVAL GATE (not assumed)
1. Approve granting Product Master authoring to the legacy uppercase `SUPER_ADMIN` spelling, and confirm the two active holders
   (`admin@oasisbaklawa.com`, `purecocoa@live.in`) are intended product authors. If either is not, the role value must be corrected
   or the identity excluded before release; the migration deliberately matches on role spelling only.
2. Confirm uppercase `ADMIN` (4 active users, all staff-readable) stays denied. Adding it is a one-word change but a separate approval.
3. Approve the production migration release through the protected workflow after Core CI is green.

## Rollback
Documented in the migration header and executed inside the pgTAP test (E01-E07): re-point the nine policies to `is_admin()`, revoke,
`DROP FUNCTION`. Pure metadata change; no data is read, rewritten or deleted. Test proves row counts unchanged, canonical admins keep
write access, legacy `SUPER_ADMIN` returns to denied. The migration must be rolled back before any later migration references the function.

## Local execution evidence (disposable PostgreSQL 16.15 + pgTAP 1.3.2, no Supabase/Docker stack)
* A faithful full replay of all 459 migrations is **not possible here**: the repo carries only a reconciliation overlay over a production
  baseline that requires the protected `materialize-production-history` path and the Supabase CLI/Docker (unavailable). 250 of 458 prior
  migrations failed on missing baseline objects, so that result was discarded.
* Instead a production-faithful reduced model (exact production `is_admin()`, `is_internal_staff`, `is_staff_role` bodies, the 22 `is_admin()`
  policy shapes, the 14 policies on the three tables, grants, NOT NULL/CHECK/UNIQUE constraints read from production) was built and the
  migration applied in a single transaction on top of it. Triggers/FKs are disabled for seeded rows (`session_replication_role=replica`); RLS is not.
* Result: **80/80 pass**. Mutation check: 10 deliberately broken migrations (add `ADMIN`, drop `is_active`, grant to `anon`, leave one policy on
  `is_admin()`, drop `SUPER_ADMIN`, SECURITY INVOKER, no `search_path`, widen categories, widen `is_admin()`, `WITH CHECK (true)`) were each caught.
* Static governance (run locally against `origin/main`): canonical-authority, production-write-authority, production-ref-authority,
  migration-base-monotonicity, migration-governance (after adding this test; it first failed with "no SQL contract test"),
  reconciliation-ledger-freeze, repo-boundaries: pass.
* NOT executed: full-schema `supabase test db`, `supabase db lint`, protected Core CI, schema-drift gate (need CI / Supabase CLI).
