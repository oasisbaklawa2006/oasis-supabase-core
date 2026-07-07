# HANDOVER_AND_INGESTION_PLAN.md

# Handover and Ingestion Plan

## Current Verified Status — 2026-07-06

- `oasis-supabase-core` repository has been created and pushed.
- `oasis-supabase-core` is currently a partial backend extraction: it contains the AI Studio Supabase folder and bridge source, but live Supabase has additional legacy/Central functions not yet imported or ownership-classified.
- Supabase project: `tcxvcatsqqertcnycuop`.
- Manual deployment from `oasis-supabase-core` has been validated for `whatsapp-studio-inbox-bridge`.
- `whatsapp-studio-inbox-bridge` is ACTIVE v17.
- `BRIDGE_CRON_SECRET` has been rotated.
- Dry-run with new bridge secret succeeded.
- `BRIDGE_ENABLED=false` must remain the safe default.
- Legacy `whatsapp-webhook` remains untouched and must not be deployed casually.
- Supabase GitHub integration may point to `oasis-supabase-core`, but production auto-deploy must remain OFF until full backend reconciliation is complete.
- Latest bridge/resolver SQL verification succeeded: message `Hi send 50 kg pyramid` was ingested, `resolver_status=resolved`, `resolver_result_json` populated, `order_quantity=50`, `confidence_band=LOW`, `clarification_required=true`.
- Next technical validation: confirm Operator Inbox UI displays the resolved low-confidence/clarification row.


## 1. Purpose

This file is the entry point for any new development engine, developer, or agent.

It prevents:

- Context loss.
- Duplicate rebuilding.
- Wrong-repo backend changes.
- Accidental legacy webhook deployment.
- Unsafe cron/backfill.
- Phase-gate violations.

## 2. Ingestion Order

Read in this order:

1. `MASTER_ARCHITECTURE.md`
2. `APP_CENTRAL_INTENT.md`
3. `APP_AI_STUDIO_INTENT.md`
4. `APP_LABELLING_INTENT.md`
5. `CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md`
6. `HANDOVER_AND_INGESTION_PLAN.md`

## 3. Current State

- Backend repo created and pushed.
- Bridge deployed from backend repo as v17.
- Bridge secret rotated.
- Dry-run passed.
- Resolver SQL succeeded.
- Bridge remains disabled.
- Operator Inbox UI validation pending.

## 4. Current Safe Commands

List functions:

```bash
npx supabase functions list --project-ref tcxvcatsqqertcnycuop
```

Deploy only bridge:

```bash
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt
```

Do not deploy:

```bash
npx supabase functions deploy whatsapp-webhook --project-ref tcxvcatsqqertcnycuop
```

## 5. Bounded Work Rule

Every future task should start with:

```txt
Maximum 5 tool calls.
No code unless explicitly requested.
No deploy unless explicitly requested.
No repository-wide search.
Stop at first blocker.
```

## 6. Current Next Work

1. Verify Operator Inbox UI shows the `Hi send 50 kg pyramid` row.
2. If hidden, patch UI filter to show low-confidence/clarification rows.
3. Keep cron off.
4. Keep bridge disabled except controlled tests.
5. Continue repo context injection into all four repos.

## 7. Production Safety

- Current app is safe.
- No migrations were run during backend extraction.
- Legacy WhatsApp webhook remains untouched.
- Supabase production auto-deploy must remain OFF.
- Full backend extraction is incomplete until all live functions are imported/classified.
