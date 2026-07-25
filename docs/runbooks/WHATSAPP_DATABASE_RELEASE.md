# WhatsApp Database Release Runbook

This runbook is fail-closed. Production deployment is a separate approval
boundary and is not authorised by PR #26.

## 1. Intake the Support Artifact

- Confirm the export is schema-only and belongs to
  `tcxvcatsqqertcnycuop`.
- Record its SHA-256 checksum, creation time, source, and support ticket.
- Inspect it for data inserts, passwords, keys, tokens, role passwords,
  connection strings, and storage-object contents. Stop if any are present.
- Preserve the 168-entry production ledger snapshot; do not edit production
  migration history.

## 2. Construct the Canonical Baseline

- Create a dedicated reconciliation branch from current Core `main`.
- Add the reviewed schema-only baseline before the seven pending migrations.
- Reconcile object ownership, grants, RLS, functions, triggers, extensions, and
  storage policy definitions.
- Keep the production project reference in `supabase/config.toml`, but do not
  link or deploy from local validation.
- Run `bash scripts/check-canonical-authority.sh`.
- Run `bash scripts/check-migration-governance.sh origin/main`.

## 3. Prove Zero-State Replay

Use the CLI version pinned in CI. Discover command flags with `--help`.

1. Start an isolated local Supabase stack.
2. Reset the local database from zero.
3. Run all pgTAP contracts.
4. Run database lint at warning level.
5. Capture the first failing migration and full diagnostic artifact on failure.
6. Stop the local stack even when a step fails.

Expected outcome: baseline plus all seven pending migrations replay cleanly and
`supabase/tests/20260725_whatsapp_case_programme_contract.sql` passes.

## 4. Preview UAT

- Obtain explicit approval for any temporary-branch cost.
- Create one isolated, data-free preview branch from the reconciled Core repo.
- Confirm the preview database is healthy and its applied ledger ends with the
  seven WhatsApp versions in the documented order.
- Run rollback-only behavioral UAT. Required scenarios:
  - packet-to-case idempotency;
  - split-message reconstruction;
  - employee sender vs original customer identity;
  - clarification before commercial mutation;
  - accountable owner and handoff;
  - outbound consent, opt-out, quiet hours, and frequency limits;
  - B2C/D2C manual queue;
  - payment-proof quarantine;
  - cross-forward deduplication;
  - reconciliation sign-off and late-exception rejection;
  - append-only case events and retirement evidence.
- Run Supabase security and performance advisors.
- Delete the temporary branch after evidence is captured.

## 5. Production GO/NO-GO

GO requires all of the following:

- clean replay and preview UAT green on the exact reviewed commit;
- no unresolved review threads or mandatory CI failures;
- production backup/recovery point confirmed;
- migration duration and lock-risk review;
- named deployment operator, observer, and rollback owner;
- low-traffic deployment window;
- explicit user approval for production deployment.

Any missing item is `NO-GO`.

## 6. Controlled Production Deployment

- Re-read production health and migration ledger immediately before deployment.
- Confirm none of the seven versions already exists.
- Apply only the reviewed Core migration chain using the approved deployment
  workflow.
- Stop on the first error. Do not repair the ledger manually.
- Re-read health, logs, advisors, schema objects, RLS, and the migration ledger.
- Run non-destructive smoke checks from Operator Inbox.

## 7. Rollback and Recovery

These migrations are additive but create governed audit records. Once production
traffic writes records, destructive down-migrations are not the default
rollback.

- First rollback: disable application feature exposure and outbound execution.
- Preserve packet capture and immutable audit evidence.
- If schema rollback is necessary, use the confirmed recovery point or a
  separately reviewed forward-fix migration.
- Never delete communication evidence or rewrite migration history to make a
  failed deployment appear successful.

## Evidence Record

| Evidence | Result | Link/checksum |
|---|---|---|
| Support schema-only artifact | Pending | |
| Baseline secret/data scan | Pending | |
| Local zero-state replay | Pending | |
| pgTAP | Pending | |
| Database lint | Pending | |
| Preview migration replay | Pending | |
| Rollback-only UAT | Pending | |
| Advisors | Pending | |
| Final production approval | Pending | |
