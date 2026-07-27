# WhatsApp Database Release Runbook

This runbook is fail-closed. Production deployment is a separate approval
boundary and is not authorised by PR #26.

## 1. Intake the Support Artifact

- Confirmed the export is schema-only and belongs to
  `tcxvcatsqqertcnycuop`.
- Recorded its SHA-256 checksum, creation time, and direct CLI source in
  `docs/reconciliation/PRODUCTION_SCHEMA_BASELINE_2026-07-27.md`.
- Inspected it for data inserts, passwords, keys, tokens, role passwords,
  connection strings, and storage-object contents. None are present.
- Preserved the 168-entry production ledger snapshot without editing production
  migration history.

## 2. Construct the Canonical Baseline

- Created a dedicated reconciliation worktree from the exact Core PR #26 head.
- Added the checksum-locked schema-only baseline before the seven pending
  migrations.
- Reconciled object ownership, grants, RLS, functions, triggers, extensions, and
  storage policy definitions.
- Added exact local counterparts for all 168 production versions, using
  comment-only compatibility stubs before the final squashed baseline.
- Archived the 41 superseded Core migrations for audit.
- Keep the production project reference in `supabase/config.toml`, but do not
  link or deploy from local validation.
- Run `bash scripts/check-canonical-authority.sh`.
- Run `bash scripts/check-migration-governance.sh origin/main`.

## 3. Prove Zero-State Replay

Completed on GitHub Actions run
[`30221700997`](https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/30221700997)
at commit `c597686f9e619f88f4b0ee81a2e706e51de25c7d`, using pinned Supabase
CLI `2.101.0`.

The isolated stack started successfully, all 168 production-history versions
plus the seven pending migrations replayed from zero, every database contract
passed, database lint passed at warning level, and the stack stopped cleanly.
No production connection or production write was involved.

## 4. Preview UAT

Completed on the existing isolated, data-free branch
`uat/core-pr26-whatsapp` (`acvghcvxemdmwoifncgz`); no new paid branch was
created. The branch database was healthy and empty before the test.

The checksum-locked baseline and all seven reviewed migrations applied in the
documented order. The sanitized infrastructure seed applied successfully. The
structural contract passed, followed by rollback-only behavioral UAT covering:

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

Rollback verification returned zero synthetic contacts, packets, cases,
outbound decisions, and reconciliation runs. Security advisors returned 238
pre-existing baseline findings (13 errors, 221 warnings, 4 informational) and
no finding against a newly added WhatsApp programme object. The temporary
branch was deleted after evidence capture.

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
| Support schema-only artifact | Passed | `c1d3b4bd7ec0f96431e06eba19cd6aab879edbe3fa89cb2ecdc756bd84f2cebb` |
| Canonical LF baseline + Storage supplement | Passed | `2b7df9c40a556b6be5e8b6cb37c4a028f31fa931cf11f5d34595151dbcbbc3ca` |
| Safe infrastructure seed | Passed | `104a57706630a4d6c3fd4fe6d1414945f4a86acb3b8bd045788da77c500cb216` |
| Baseline secret/data scan | Passed | 0 DML/data/password/token/connection-string findings |
| Production ledger parity | Passed | 168/168 versions |
| Isolated zero-state replay | Passed | GitHub Actions `30221700997`, commit `c597686f…` |
| pgTAP | Passed | `Clean database replay and pgTAP contracts` |
| Database lint | Passed | Supabase CLI `2.101.0`, warning level |
| Preview migration replay | Passed | Data-free branch `acvghcvxemdmwoifncgz`; baseline + 7 in order |
| Rollback-only UAT | Passed | 12 governed scenarios; all synthetic counts returned to zero |
| Advisors | Disposition recorded | 238 baseline findings; 0 on new WhatsApp programme objects |
| Temporary UAT branch cleanup | Passed | Branch `828f34e4-a479-43ec-9844-851736df1db7` deleted |
| Final production approval | Pending | |
