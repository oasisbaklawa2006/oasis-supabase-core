# Oasis Enterprise Software Handover Index

Generated: 2026-07-07 11:20 UTC

## Purpose

This `.ai-intent` handover pack lets a new development engine continue the Oasis Baklawa enterprise system without rebuilding working features, touching protected legacy endpoints, or violating phase gates.

## Canonical Reading Order

1. `CURRENT_STATUS_LEDGER.md`
2. `CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md`
3. `REPO_MAP.md`
4. `SCREEN_REGISTRY.md`
5. `API_AND_EDGE_FUNCTION_REGISTRY.md`
6. `DATABASE_LEDGER.md`
7. `ACCESS_CONTROL_LEDGER.md`
8. `SECRETS_INVENTORY_TEMPLATE.md`
9. `FINAL_E2E_EVIDENCE_TEMPLATE.md`
10. Runbooks:
   - `RUNBOOK_WHATSAPP_WEBHOOK_HEALTH.md`
   - `RUNBOOK_STUDIO_BRIDGE_DEPLOY_AND_TEST.md`
   - `RUNBOOK_BRIDGE_CURSOR_AND_BACKFILL.md`
   - `RUNBOOK_SECRET_ROTATION.md`
   - `RUNBOOK_OPERATOR_INBOX_TEST.md`
   - `RUNBOOK_RLS_TEAM_ACCESS.md`
11. `DEVELOPMENT_ENGINE_PROMPT.md`

## Non-Negotiable Warnings

- Do not deploy or modify `whatsapp-webhook` from AI Studio.
- Do not move to scheduled bridge polling until final E2E evidence is recorded.
- Do not backfill historical WhatsApp messages blindly.
- Do not add secret values to repo, chat, markdown, screenshots, or issue comments.
- Do not convert WhatsApp sales order drafts into live Sales Orders until Golden Pipeline promotion is explicitly built and validated.
- Do not proceed into Phase 2 dependency expansion until Phase 1 admin UI stability is validated.

## Current Highest-Value Next Work

1. Record one fresh post-webhook-recovery E2E evidence packet.
2. Decide bridge operating mode: manual development mode or scheduled polling.
3. Freeze cursor/backlog strategy.
4. Validate and maintain the 62-screen registry.
5. Continue Phase 1 UI closeout before Phase 2 expansion.
