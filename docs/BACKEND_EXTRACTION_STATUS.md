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

## Safety Status

- Legacy whatsapp-webhook was not deployed
- Meta callback was not changed
- Supabase database migrations were not run
- Current frontend apps were not changed
- Current production app was not affected

## Important Limitation

Baseline intake and ledger reconciliation are complete, but isolated replay,
pgTAP, database lint, security disposition, and preview UAT are not yet proven.
Therefore:

- Supabase GitHub auto production deployment must remain OFF
- Cron must remain OFF
- BRIDGE_ENABLED must remain false unless a controlled test is being run
- Full backend reconciliation remains deployment-blocked
- Supabase preview branching must remain OFF until clean replay passes and a
  temporary-branch cost is explicitly approved
- The seven WhatsApp migrations must remain unapplied until that proof passes

## Current Approved Deployment

Only whatsapp-studio-inbox-bridge is approved for controlled manual deployment from this repo.

Approved command:
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt

## Prohibited Casual Deployment

Do not casually deploy whatsapp-webhook.

## Next Technical Step

1. Prove a clean isolated CI replay of the baseline plus the seven pending
   WhatsApp migrations.
2. Run pgTAP and database lint on that exact commit.
3. Record the disposition of the pre-existing Supabase security-advisor
   findings.
4. After cost approval, run rollback-only database UAT on one isolated preview
   branch.

No production migration, migration-history repair, or GitHub auto-deployment is
authorised by this repository change.
