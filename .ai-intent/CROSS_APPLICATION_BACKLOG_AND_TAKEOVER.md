# CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md

# Cross-Application Backlog and Takeover Instructions

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


## 1. Current Exact Takeover Point

The backend repository split is partially complete and validated:

- `oasis-supabase-core` exists.
- `supabase/` copied from AI Studio.
- Manual bridge deployment from backend repo succeeded.
- Bridge version v17 active.
- Secret rotated.
- Dry run succeeded.
- Resolver SQL verification succeeded.
- `BRIDGE_ENABLED=false`.
- Legacy `whatsapp-webhook` untouched.

Next technical task:

```sql
select
  provider_message_id,
  message_body,
  resolver_status,
  resolver_result_json,
  created_at
from whatsapp_inbound_messages
order by created_at desc
limit 1;
```

Already verified latest result: resolved, populated JSON, low confidence, clarification required.

Next practical task: Operator Inbox UI visibility validation.

## 2. Do Not Rebuild

Do not rebuild:

- Bridge ingestion.
- Resolver runtime foundation.
- Sales order draft foundation.
- Operator inbox foundation.
- Backend repo initial extraction.
- Alias schema patch.

## 3. Do Not Touch

Do not casually deploy:

- `whatsapp-webhook`

Do not enable:

- Supabase production auto-deploy.
- Bridge cron.

Do not change:

- Meta callback URL.

## 4. Repositories

Final target repositories:

- `oasis-supabase-core`
- `oasis-baklawa-central`
- `oasis-ai-studio`
- `oasis-trace`

Each repo must contain the full `.ai-intent/` folder.

## 5. Remaining Repo Fix Steps

1. Put `.ai-intent/` in `oasis-supabase-core`.
2. Commit and push.
3. Copy same `.ai-intent/` to `oasis-ai-studio`.
4. Add/update frontend `BACKEND_OWNERSHIP.md`.
5. Commit and push.
6. Copy same `.ai-intent/` to `oasis-baklawa-central`.
7. Add/update frontend `BACKEND_OWNERSHIP.md`.
8. Commit and push.
9. Copy same `.ai-intent/` to `oasis-trace`.
10. Add/update frontend `BACKEND_OWNERSHIP.md`.
11. Commit and push.
12. Verify all 4 repos on GitHub.
13. Keep Supabase production auto-deploy OFF.

## 6. Backlog

Central:

- Warehouse segmentation.
- Gatekeeper.
- Finance documents.
- CMD dashboard.
- Tickets.
- Approval engine.
- Draft-to-live SO promotion.

AI Studio:

- Operator Inbox UI visibility.
- Catalogue PDF variants.
- Compliance datasets.
- Product publication gates.

Trace:

- Labels.
- Barcodes.
- Printer bridge.
- Tracking nodes.
- Reprint governance.

Supabase Core:

- Import/classify all live functions.
- Add deployment runbooks.
- Add CI guard.
- Reconcile migrations.
- Keep auto production deploy OFF until full reconciliation.
