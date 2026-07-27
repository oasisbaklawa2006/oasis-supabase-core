# Production Schema Baseline — 2026-07-27

## Provenance

- Supabase project: `tcxvcatsqqertcnycuop`
- Source: direct `supabase db dump` schema-only export supplied by the project
  owner
- Source filename: `oasis-production-schema.sql`
- Source checksum:
  `c1d3b4bd7ec0f96431e06eba19cd6aab879edbe3fa89cb2ecdc756bd84f2cebb`
- Canonical baseline:
  `supabase/migrations/20260723161256_legacy_role_authority_baseline.sql`
- Canonical checksum:
  `2b7df9c40a556b6be5e8b6cb37c4a028f31fa931cf11f5d34595151dbcbbc3ca`
- Infrastructure seed: `supabase/seed.sql`
- Infrastructure seed checksum:
  `104a57706630a4d6c3fd4fe6d1414945f4a86acb3b8bd045788da77c500cb216`
- Transformation: line endings and trailing whitespace normalized, then 15
  production-verified policies on `storage.objects` were appended because the
  default dump excludes custom objects in Supabase-managed schemas.

The baseline version is the final version in the preserved 168-entry production
ledger. Production already records that version as applied, so the baseline SQL
will run on empty databases but will not be reapplied to production.

## Intake Validation

| Check | Result |
|---|---:|
| Tables | 196 |
| Functions | 99 |
| Public-schema RLS policies from dump | 424 |
| Verified `storage.objects` policies appended | 15 |
| Canonical policy total | 439 |
| `COPY` statements | 0 |
| `INSERT` statements | 0 |
| `UPDATE` statements | 0 |
| `DELETE` statements | 0 |
| Connection strings | 0 |
| Password statements | 0 |
| JWT/API-key patterns | 0 |
| NUL bytes | 0 |
| Required WhatsApp dependencies | Present |
| Safe infrastructure/reference seed rows | 38 |
| Production cron command bodies committed | 0 |

`scripts/check-production-baseline.sh` enforces the checksum, object inventory,
secret/data scan, ledger alignment, stub-only history, and required dependency
set on every relevant pull request.

The seed restores only non-sensitive infrastructure/reference state required by
empty local and preview environments: eight bucket definitions, eight bucket
contracts, three Realtime contracts, two retry policies, the bridge singleton,
four access permissions, and twelve role grants. It contains no users, orders,
messages, files, credentials, vault values, or cron commands.

Production has three active Cron jobs. Two command bodies matched a
secret-bearing heuristic, so no Cron command body was retrieved into evidence
or committed. Cron restoration is intentionally outside this data-free
baseline and requires a separate secrets-controlled environment procedure.

## History-Preserving Squash

Core previously contained 41 active migrations, but none of their versions
matched any of the 168 versions in production. A normal `db push` therefore
could not treat Core as authoritative.

The reconciled chain uses this structure:

1. The first 167 production versions are represented by comment-only
   compatibility stubs.
2. Version `20260723161256` contains the complete schema-only production
   baseline.
3. The seven new WhatsApp communication-case migrations follow the baseline.
4. The 41 superseded Core files are retained under
   `supabase/archived-migrations/pre-production-baseline-20260727/` for audit.

This provides deterministic empty-database replay while preserving exact
version parity with production. It does not insert, delete, rename, or repair
any production migration-ledger row.

## Independent Security Findings

The baseline faithfully reflects the live schema; it does not silently alter
pre-existing security behavior. A read-only Supabase security-advisor check on
2026-07-27 returned 231 findings: 13 errors, 214 warnings, and 4 informational
items. The errors are 13 public security-definer views granted to `anon` and
`authenticated`. Warnings also include mutable function search paths,
over-permissive RLS policies, public buckets, executable `SECURITY DEFINER`
functions, and disabled leaked-password protection.

These findings are not introduced by this reconciliation. They require a
separate, explicitly approved remediation tranche because correcting them
changes production authorization behavior. PR #26 remains deployment-blocked
until zero-state replay passes and the security disposition is recorded.

Supabase remediation reference:
https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view
