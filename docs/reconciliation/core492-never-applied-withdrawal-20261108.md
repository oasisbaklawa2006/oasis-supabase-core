# Core #492 — protected withdrawal of never-applied staging migrations

Date: 2026-11-08
Status: **Proposed; requires independent human approval and passing protected CI.**

## Scope and evidence

The owner instructed that merged Core PR #492 be reversed after the initial red migration-drift watch. The red watch was caused by pending, **undeployed** versions `20261107123000` and `20261107124500`; the protected source pgTAP replay passed 307 files and 5,385 tests.

Core merge commit: `678fa78da53f0e92c5aa8a908376a5eb5189393a`.
Previous protected main: `e8bc44a5c59526f019760be663ff54e35b47cf2e`.

Release [42499231129](https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/42499231129) was **cancelled** after successful preflight. Its production deployment job did **not** apply either migration. Authoritative production project `tcxvcatsqqertcnycuop` had 463 applied migration records, latest `20261107114000`, neither new staging version, no `product-media-staging` bucket and no new staging RLS policies at the withdrawal checkpoint.

The only two archived-in-Git historical migration blobs are:

- `supabase/migrations/20261107123000_studio_private_raw_media_staging_v1.sql`: Git blob `9b7af5da3344e0d3c1e2fe65a6f4b15f7930b55c`
- `supabase/migrations/20261107124500_studio_private_media_permission_scope_v1.sql`: Git blob `29147e6abe4cd712781c1eb2b11fc95b48eef426`

## Withdrawal implementation

Use one new protected pull-request commit to **remove only these two never-applied migration files** from the active Supabase migration directory, remove the private-staging-only pgTAP suite, and restore the shared rollback test to its exact post-#491 version. Source history remains intact: the immutable SQL is retained in the original #492 merge and Git object database. No Git force-push or production SQL/DDL is authorized.

The migration chronology checks retain the normal prohibition on edits, renames, and deletes. The narrowly pinned withdrawal exception recognizes only deletion of **both** above exact paths, from the exact #492 merge parent, with exact historical Git blob identifiers, and this immutable manifest blob identifier. Every other migration modification or deletion remains forbidden, including deleting either migration in a different release or from a different parent.

Before protected merge, independently verify the production ledger still has neither withdrawn migration version, and the staging bucket and policies remain absent. If either was applied elsewhere, **DO NOT MERGE** this withdrawal; investigate and use a forward compensating migration instead. All seven protected checks and code-owner approval are required.

The chronology ceiling preserves historical version `20261107124500` even after withdrawal; future legitimate migrations must have strictly newer versions. This withdrawal does not fix the separately confirmed exposed raw-media file in a legacy public Storage bucket. AI Studio G3 media-security certification remains **NO-GO** until safe private-media handling is implemented and verified in a new independently reviewed train.
