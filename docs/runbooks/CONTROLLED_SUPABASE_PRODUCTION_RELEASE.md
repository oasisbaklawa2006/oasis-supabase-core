# Controlled Supabase Production Release

> **PRODUCTION MIGRATION INVARIANT**
>
> A production schema change is valid only when the migration already exists
> on protected `oasis-supabase-core/main` and is applied by `Production
> Migration Release`. Any other production migration version is a **P0
> governance incident**.
>
> This invariant is enforced mechanically, not just by convention:
> `scripts/check-production-write-authority.sh` fails any tracked file that
> contains a production-capable schema-write command outside
> `scripts/run-production-migration-overlay.sh` (invoked exclusively by this
> workflow's protected `deploy` job), runs in every Core PR and on `main`,
> and is re-enforced immediately before every deployment. See
> `docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md`
> for the incident this permanently guards against.

## Objective

Keep GitHub Core and Supabase production on one exact migration ledger. Prevent remote-only versions, missed deployments, concurrent pushes, silent dashboard changes and unverified production schema updates.

## Single source of truth

- Repository: `oasisbaklawa2006/oasis-supabase-core`
- Branch: `main`
- Production project ref: `tcxvcatsqqertcnycuop`
- Canonical migration directory: `supabase/migrations`
- Production ledger: `supabase_migrations.schema_migrations`

No other repository, workstation, chat thread, SQL editor or dashboard is an authorized production migration source.

## Release sequence

1. A migration is created once with `supabase migration new <name>`.
2. Its timestamp filename is never renamed or copied to another timestamp.
3. The pull request passes migration governance, clean replay, pgTAP and lint.
4. The pull request merges to Core `main`.
5. `Production Migration Release` starts automatically.
6. The read-only preflight compares every local version with the production ledger.
7. Deployment stops if a remote-only version, duplicate version or non-append pending version exists.
8. The Supabase CLI performs `db push --dry-run` and stores evidence.
9. The `supabase-production` GitHub environment requires approval before write access.
10. The exact approved commit is checked out and the ledger is re-verified immediately before deployment.
11. A single serialized `supabase db push` applies pending files in timestamp order.
12. The production ledger must exactly match Core after deployment.
13. Read-only contract smoke tests run and one-year deployment evidence is retained.

## Required GitHub configuration

Create two GitHub environments.

### `supabase-production-readonly`

Variables:

- `SUPABASE_PROJECT_REF=tcxvcatsqqertcnycuop`

Secrets:

- `SUPABASE_DB_URL` — production Postgres connection URL with the minimum access needed to read `supabase_migrations.schema_migrations` and run read-only verification.
- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_DB_PASSWORD`

No required reviewer is necessary for this environment.

### `supabase-production`

Variables:

- `SUPABASE_PROJECT_REF=tcxvcatsqqertcnycuop`

Secrets:

- `SUPABASE_DB_URL`
- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_DB_PASSWORD`

Controls:

- Require at least one production reviewer.
- Prevent self-review when supported.
- Limit deployment branches to `main`.
- Do not expose these secrets at repository scope.

## Required branch protection

Require these checks on Core pull requests:

- `Migration naming, safety and contract tests`
- `Clean database replay and pgTAP contracts`
- repository ownership boundary check

Require pull requests for changes to:

- `supabase/migrations/**`
- `scripts/check-migration-governance.sh`
- `scripts/verify-production-migration-ledger.sh`
- `.github/workflows/production-migration-*.yml`

## Drift sentinel

`Production Migration Drift Watch` runs on every push to `main` that touches
migrations/reconciliation evidence, plus four times daily (02:17, 08:47,
14:17, 20:47 UTC) as a read-only, push-independent recurring check. It also
enforces `scripts/check-production-write-authority.sh` and
`scripts/check-production-ref-authority.sh`. It fails when:

- production contains a version absent from Core;
- Core contains a merged migration that is still not deployed;
- duplicate or malformed local versions are detected;
- a pending migration is older than the latest production version;
- a production-capable write path exists outside the governed release, or
  the production project ref is mislabeled as non-production.

A failing sentinel is a release blocker. Do not use `migration repair` automatically.

## Emergency rule

Direct production SQL is prohibited. If a critical incident makes it unavoidable:

1. Record the incident and exact SQL before execution.
2. Use a transaction and a named change window.
3. Immediately create the same canonical migration in Core using the exact intended ledger version.
4. Reconcile through a reviewed PR.
5. Run the drift sentinel and schema verification before closing the incident.

Migration history repair is never an automatic recovery action. It requires a documented evidence review proving whether the SQL effect already exists.

## Failure handling

### Remote-only migration

- Stop all deployments.
- Identify who or what applied it.
- Export its exact SQL effect.
- Add the historical version to Core as an executable migration or compatibility record, based on verified state.
- Re-run clean replay and production ledger verification.

### Pending migration fails

- Do not rename it.
- Do not create a replacement timestamp.
- Correct the same unapplied migration file on a new PR.
- Re-run the full pipeline.

### Partially applied migration

- Treat as a production incident.
- Inspect transaction behavior and ledger state.
- Create a forward-only corrective migration.
- Never delete production ledger rows without separately approved reconciliation evidence.

## Certification condition

Supabase migration release is certified only when all are true:

- local and production migration version sets are identical;
- no production-only version exists;
- no merged migration remains pending;
- clean replay and pgTAP pass on the deployed commit;
- post-deployment smoke tests pass;
- deployment evidence artifact exists;
- the drift sentinel is green.
