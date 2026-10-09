# Production lineage incident — #384/#385 never-live pair

-- production-lineage-incident-approved: PR #391 reconciles the never-applied #384/#385 source-history pair required by the protected PR #387 production release preflight.

## Scope

This record is limited to the migration-lineage reconciliation discovered after PR #387 merged as `76030dc617f36072c0e75ea3e25b53ec981c8441`.

The affected canonical-local migration versions are:

- `20261001233000_b2b_reapply_after_rejection.sql` from PR #384.
- `20261002140000_b2b_reapplication_policy_revert.sql` from PR #385.

Neither migration version is present in the production `supabase_migrations.schema_migrations` ledger.

## Read-only production evidence

Production project: `tcxvcatsqqertcnycuop`.

Read-only catalog verification established:

- `uq_b2b_applications_email_mobile` is the pre-#384 unique index over `lower(contact_email), mobile_number` without a rejected-status exclusion.
- `submit_b2b_access_request_v2(...)` has the pre-#384 behavior that returns an existing application for a matching canonical email/mobile identity.
- There are zero duplicate canonical email/mobile identity groups.
- Neither `20261001233000` nor `20261002140000` is recorded in the production migration ledger.

PR #385 itself documents that PR #384 was merged to Git but never applied to production and that #385 is an append-only source-history correction restoring the production-approved pre-#384 behavior on clean replay.

## Reconciliation decision

The pair is net-neutral relative to production. Deploying either historical migration now would create unnecessary business-state churn and would violate the PR #387 release instruction to deploy only genuinely pending append-only work.

Therefore both canonical-local versions are recorded as `represented_remote`: their final intended state is already represented by the verified production catalog even though neither historical version was individually applied there.

This change does not alter migration SQL, schema, data, RLS, functions, or production state. It only extends the frozen canonical-lineage evidence and updates the corresponding verifier/overlay regression cardinalities.

## Release boundary

This incident record does not authorize unrelated migrations or open PRs. In particular, unrelated open migration PRs remain subject to the existing release-ceiling guard and must not be closed, retimestamped, or bypassed by this reconciliation.
