# Backend Extraction Status

## Current Status

oasis-supabase-core is the designated canonical Supabase backend authority for
the Oasis ecosystem. Its local project reference now matches the live
`oasis-baklawa` project (`tcxvcatsqqertcnycuop`).

## Completed

- Repository created: oasis-supabase-core
- main branch pushed to GitHub
- supabase folder copied from oasis-ai-studio
- Backend ownership documentation added
- Function ownership documentation added
- Manual deployment from oasis-supabase-core validated
- whatsapp-studio-inbox-bridge deployed successfully from this repo
- Bridge version confirmed as v17
- Bridge secret rotated
- Dry-run with new bridge secret succeeded
- BRIDGE_ENABLED=false retained for safety
- Seven pending WhatsApp communication-case migrations reconciled from Central
  into Core without applying them to production
- A rollback-only database contract added for the complete seven-migration
  WhatsApp programme
- Production schema-only export accepted and checksum-locked
- All 168 production migration versions represented exactly in Core
- Complete production schema anchored to the final applied ledger version
- Fifteen custom Storage policies restored from read-only production evidence
- Thirty-eight non-sensitive infrastructure/reference rows added as a local
  and preview seed
- Forty-one divergent Core migrations moved to an audit archive
- Isolated zero-state replay passed on GitHub Actions at commit `c597686f…`
- All database contracts and database lint passed on the replayed schema
- Data-free preview replay and rollback-only WhatsApp behavioral UAT passed
- Preview synthetic data rollback was verified at zero remaining test rows
- Security disposition recorded: no advisor finding targets a newly added
  WhatsApp programme object
- Temporary UAT branch deleted after evidence capture

## Safety Status

- Legacy whatsapp-webhook was not deployed
- Meta callback was not changed
- Supabase database migrations were not run
- Current frontend apps were not changed
- Current production app was not affected

## Important Limitation

Baseline intake, ledger reconciliation, isolated replay, pgTAP, database lint,
security disposition, and preview UAT are complete. Production release
readiness and explicit deployment approval are not complete. Therefore:

- Supabase GitHub auto production deployment must remain OFF
- Cron must remain OFF
- BRIDGE_ENABLED must remain false unless a controlled test is being run
- Full backend reconciliation remains deployment-blocked
- The seven WhatsApp migrations must remain unapplied until the final
  production GO requirements pass and explicit approval is recorded

## Current Approved Deployment

Only whatsapp-studio-inbox-bridge is approved for controlled manual deployment from this repo.

Approved command:
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt

## Prohibited Casual Deployment

Do not casually deploy whatsapp-webhook.

## Next Technical Step

1. Confirm the production recovery point and rollback owner.
2. Complete migration duration and lock-risk review.
3. Name the deployment operator and observer and select a low-traffic window.
4. Obtain explicit final approval before any production migration.

No production migration, migration-history repair, or GitHub auto-deployment is
authorised by this repository change.
