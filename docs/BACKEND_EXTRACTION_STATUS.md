# Backend Extraction Status

## Current Status

oasis-supabase-core has been created as the canonical Supabase backend authority for the Oasis ecosystem.

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

## Safety Status

- Legacy whatsapp-webhook was not deployed
- Meta callback was not changed
- Supabase database migrations were not run
- Current frontend apps were not changed
- Current production app was not affected

## Important Limitation

This repository is currently a partial backend extraction.

It contains the AI Studio Supabase folder and the Studio bridge source, but the live Supabase project also contains additional active legacy and Central functions that are not yet imported or ownership-classified.

Therefore:

- Supabase GitHub auto production deployment must remain OFF
- Cron must remain OFF
- BRIDGE_ENABLED must remain false unless a controlled test is being run
- Full backend reconciliation is still pending

## Current Approved Deployment

Only whatsapp-studio-inbox-bridge is approved for controlled manual deployment from this repo.

Approved command:
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt

## Prohibited Casual Deployment

Do not casually deploy whatsapp-webhook.

## Next Technical Step

Verify post-ingestion resolver output in whatsapp_inbound_messages using Supabase SQL Editor.

Expected result:
- resolver_status should not be failed
- resolver_result_json should not be null
