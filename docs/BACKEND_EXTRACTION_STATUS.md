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

## Safety Status

- Legacy whatsapp-webhook was not deployed
- Meta callback was not changed
- Supabase database migrations were not run
- Current frontend apps were not changed
- Current production app was not affected

## Important Limitation

This repository still requires one baseline-reconciliation step before it can
be used for preview branching or production migration deployment.

It contains the AI Studio Supabase folder and the Studio bridge source, but the live Supabase project also contains additional active legacy and Central functions that are not yet imported or ownership-classified.

The production migration ledger and the historical files in this repository
are not yet a proven one-to-one chain. Therefore:

- Supabase GitHub auto production deployment must remain OFF
- Cron must remain OFF
- BRIDGE_ENABLED must remain false unless a controlled test is being run
- Full backend reconciliation is still pending
- Supabase preview branching must remain OFF until a schema-only production
  baseline has been exported and clean replay is proven
- The seven WhatsApp migrations must remain unapplied until that proof passes

## Current Approved Deployment

Only whatsapp-studio-inbox-bridge is approved for controlled manual deployment from this repo.

Approved command:
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt

## Prohibited Casual Deployment

Do not casually deploy whatsapp-webhook.

## Next Technical Step

1. Export the live production schema without rows, secrets, or migration-ledger
   mutation.
2. Reconcile that schema-only baseline with the 168 production migration
   versions.
3. Prove a clean local replay of the baseline plus the seven pending WhatsApp
   migrations.
4. Run rollback-only database UAT on an isolated preview branch.

No production migration, migration-history repair, or GitHub auto-deployment is
authorised by this repository change.
