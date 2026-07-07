# AI Engine Dos and Don'ts / Functional Boundaries

Generated: 2026-07-07
Purpose: Mandatory operating boundaries for any AI/dev engine taking over the Oasis Baklawa enterprise app ecosystem.

This file is a functional guardrail. Any AI engine continuing development must follow these rules.


# Cost, Cursor, and Loop-Control Boundary

The AI engine must also follow `.ai-intent/CURSOR_COST_CONTROL_POLICY.md`.

Economy is mandatory. The engine must conserve money, Cursor credits, AI tokens, tool calls, and developer time. It must not enter endless loops, repeat the same failed fix, or allow Cursor/agent mode to run without a bounded objective and stop condition.

Mandatory controls:

- Stop after two failed attempts on the same issue and switch to diagnosis.
- Never ask Cursor to “fix everything” or “continue until done.”
- Before any Cursor Agent/Composer run, define allowed files, forbidden files, success condition, and stop condition.
- Prefer targeted read-only evidence before broad scans, full builds, deployments, or repo-wide edits.
- Do not repeat a failed command unless there is new evidence that the failure condition changed.
- Do not let Cursor make broad unrelated changes to consume credits.
- Use the smallest safe command, test, and diff that proves the point.
- Treat unnecessary AI/Cursor usage as operational waste.

---

# 1. Golden Rule

Do not break working production flows while trying to complete planned features.

Known working flow:
WhatsApp inbound message -> legacy whatsapp-webhook -> public.whatsapp_messages -> whatsapp-studio-inbox-bridge -> public.whatsapp_inbound_messages -> resolver -> Operator Inbox -> operator decision audit -> WhatsApp sales order draft.

# 2. Repository Ownership Boundaries

| Repo | Owns | Must Not Own |
|---|---|---|
| oasis-supabase-core | Shared schema, migrations, RLS, edge infrastructure, database runbooks | UI-specific business behavior without repo owner approval |
| oasis-baklawa-central | ERP, Golden Pipeline, sales orders, finance, dispatch, warehouse, admin | AI catalogue truth or uncontrolled AI media generation |
| oasis-ai-studio | Product intelligence, catalogue governance, resolver, AI media, Studio inbox bridge | Final invoice, dispatch, stock movement, legacy WhatsApp webhook ownership |
| oasis-trace | Labels, stickers, barcode, QR, batch/lot traceability | Product master truth, live order truth, finance truth |

# 3. Mandatory Dos

## Architecture / Planning

- Read HANDOVER_INDEX.md first.
- Read FINAL_E2E_EVIDENCE.md before touching WhatsApp or bridge code.
- Read FEATURE_REGISTRY.md before claiming a feature is built.
- Read SCREEN_REGISTRY.md before creating a new screen.
- Update registries whenever a feature changes status.
- Maintain repo ownership boundaries.
- Use evidence instead of assumptions.

## Git / Change Control

- Inspect git status before changes.
- Use focused commits with clear messages.
- Keep changes reviewable.
- Run typecheck/build/tests where available.
- Include SQL verification for database changes.
- Document production-impacting changes in .ai-intent.

## Supabase / Database

- Run read-only preflight SQL before mutating SQL.
- Make migrations idempotent where possible.
- Preserve RLS unless deliberately changing access.
- Verify RLS using actual logged-in users.
- Preserve append-only audit tables.
- Use service-role logic only in trusted server/edge contexts.
- Keep frontend code on anon-key/RLS-safe paths.
- Verify live schema names before writing SQL.
- Check columns using information_schema.columns before assuming names.

## WhatsApp / Bridge

- Keep BRIDGE_ENABLED=false unless performing a controlled test.
- Use bridge dry-run before live bridge execution.
- Check whatsapp_studio_inbox_bridge_state after bridge runs.
- Document cursor decisions before backfill.
- Verify public.whatsapp_messages receives fresh rows before blaming Studio.
- Confirm duplicate handling before replaying messages.

## Resolver / Product

- Treat LOW confidence as requiring operator clarification.
- Preserve operator select/confirm/reject audit.
- Validate catalogue loader against live schema.
- Preserve product SKU integrity.
- Avoid changing SKU semantics without migration and business approval.

## Sales Order / Finance / Dispatch

- Keep WhatsApp drafts separate from live Sales Orders.
- Preserve readiness gates and workflow transitions.
- Keep finance, dispatch, invoice, and stock movement behind Golden Pipeline controls.
- Require explicit approval before building draft-to-live-SO promotion.

## Security / Secrets

- Store secret values only in local files or Supabase secret manager.
- Commit only secret names/templates, never values.
- Rotate any secret pasted into chat, screenshot, issue, or repo.
- Scan docs before commit.
- Treat service role keys as production-sensitive.

# 4. Mandatory Don'ts

- Do not redeploy or modify whatsapp-webhook from AI Studio.
- Do not enable scheduled bridge polling without written approval.
- Do not backfill historical WhatsApp rows blindly.
- Do not commit secret values.
- Do not place service role keys in frontend code.
- Do not bypass RLS to make UI work.
- Do not delete or rewrite audit logs.
- Do not convert WhatsApp drafts into live Sales Orders until promotion is explicitly built and validated.
- Do not generate invoices, dispatch, or stock movements from WhatsApp drafts directly.
- Do not change product SKUs casually.
- Do not assume screen existence equals feature completion.
- Do not run a file path inside Supabase SQL Editor.
- Do not run destructive SQL without backup/preflight/rollback plan.
- Do not allow Cursor or any AI agent to run open-ended loops.
- Do not repeat the same failed fix more than twice.
- Do not run broad repo scans, full builds, or deployments when a targeted read-only check is enough.
- Do not use vague prompts such as “fix everything”, “continue until done”, or “make production ready” without a bounded checklist.
- Do not spend credits on speculative refactors or unrelated cleanup.
- Do not add cron automation before duplicate/cursor/backfill policy is frozen.
- Do not point Meta/service-provider callback to Studio bridge.
- Do not replace the legacy webhook with the Studio bridge.
- Do not treat duplicate bridge rows as failure if duplicate count increments and error is null.
- Do not reset bridge cursor to an old date without backfill plan.
- Do not disable RLS to hide access bugs.
- Do not add permissive true policies on production tables.
- Do not drop columns/tables without dependency search.
- Do not use guessed column names in production SQL.
- Do not mutate production data to test UI unless explicitly approved.
- Do not allow AI-generated product results to become product truth without approval.
- Do not auto-approve aliases without governance.
- Do not let resolver confidence directly create financial/stock documents.
- Do not allow AI media generation to overwrite original product assets.
- Do not use AI output as legal/GST truth without human/legal review.

# 5. Hard Stops Requiring Human Approval

1. Enabling scheduled bridge polling
2. Historical WhatsApp backfill
3. Changing whatsapp-webhook
4. Rotating production provider tokens
5. Modifying RLS on production tables
6. Creating live Sales Orders from WhatsApp drafts
7. Creating invoices from AI/WhatsApp data
8. Moving stock based on AI/WhatsApp data
9. Deleting production rows
10. Changing product SKU structure
11. Changing GST/HSN classification logic
12. Changing customer credit/payment enforcement
13. Changing production Vercel/Supabase environment variables
14. Running bulk updates in production
15. Changing auth roles or is_team_member logic
16. Large Cursor/AI agent runs without a bounded scope and stop condition
17. Continuing after two failed attempts on the same issue

# 6. Required Validation Before Declaring Any Feature Complete

A feature may only be marked BUILT_VALIDATED after UI, database, RLS/auth, workflow, audit/error path, evidence, and registry updates are complete.

# 7. Emergency Recovery Rules

If WhatsApp messages stop appearing: check public.whatsapp_messages first; if no fresh rows exist, inspect legacy whatsapp-webhook logs/provider delivery; do not debug Studio bridge first.

If Operator Inbox shows no messages: check public.whatsapp_inbound_messages, RLS, is_team_member(auth.uid()), and logged-in user mapping; do not remove RLS.

If resolver fails: check resolver_status, resolver_result_json, catalogue loader, and product alias schema; do not hardcode products in UI as a workaround.

# 8. One-Line Mandate

Preserve the proven pipeline, document every boundary crossing, and never allow AI convenience to bypass ERP governance.
