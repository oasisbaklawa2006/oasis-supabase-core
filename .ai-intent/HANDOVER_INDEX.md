# Oasis Enterprise Software Handover Index

Generated: 2026-07-07 11:20 UTC

## Purpose

This `.ai-intent` handover pack lets a new development engine continue the Oasis Baklawa enterprise system without rebuilding working features, touching protected legacy endpoints, or violating phase gates.

## Canonical Reading Order

1. `CURRENT_STATUS_LEDGER.md`
2. `CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md`
3. `REPO_MAP.md`
4. `FEATURE_REGISTRY.md`
5. `SCREEN_REGISTRY.md`
6. `API_AND_EDGE_FUNCTION_REGISTRY.md`
7. `DATABASE_LEDGER.md`
8. `ACCESS_CONTROL_LEDGER.md`
9. `SECRETS_INVENTORY_TEMPLATE.md`
10. `FINAL_E2E_EVIDENCE_TEMPLATE.md`
10. Runbooks:
   - `RUNBOOK_WHATSAPP_WEBHOOK_HEALTH.md`
   - `RUNBOOK_STUDIO_BRIDGE_DEPLOY_AND_TEST.md`
   - `RUNBOOK_BRIDGE_CURSOR_AND_BACKFILL.md`
   - `RUNBOOK_SECRET_ROTATION.md`
   - `RUNBOOK_OPERATOR_INBOX_TEST.md`
   - `RUNBOOK_RLS_TEAM_ACCESS.md`
11. `AI_ENGINE_DOS_AND_DONTS.md`
12. `CURSOR_COST_CONTROL_POLICY.md`
13. `INDUSTRIAL_GRADE_DELIVERY_POLICY.md`
14. `QUALITY_GATES_AND_DEFINITION_OF_DONE.md`
15. `PRODUCT_BUSINESS_EXCELLENCE_POLICY.md`
16. `DEVELOPMENT_ENGINE_PROMPT.md`

## Non-Negotiable Warnings

- Do not deploy or modify `whatsapp-webhook` from AI Studio.
- Do not move to scheduled bridge polling until final E2E evidence is recorded.
- Do not backfill historical WhatsApp messages blindly.
- Do not add secret values to repo, chat, markdown, screenshots, or issue comments.
- Do not build feature bloat; follow `PRODUCT_BUSINESS_EXCELLENCE_POLICY.md` for business value and usability.
- Do not mark a feature complete without passing `QUALITY_GATES_AND_DEFINITION_OF_DONE.md`.
- Do not violate `INDUSTRIAL_GRADE_DELIVERY_POLICY.md`; optimize for safe, fast, economical, correct, business-useful delivery.
- Do not violate `CURSOR_COST_CONTROL_POLICY.md`; avoid endless loops and protect Cursor/AI credits.
- Do not violate `AI_ENGINE_DOS_AND_DONTS.md` functional boundaries.
- Do not convert WhatsApp sales order drafts into live Sales Orders until Golden Pipeline promotion is explicitly built and validated.
- Do not proceed into Phase 2 dependency expansion until Phase 1 admin UI stability is validated.

## Current Highest-Value Next Work

1. Record one fresh post-webhook-recovery E2E evidence packet.
2. Decide bridge operating mode: manual development mode or scheduled polling.
3. Freeze cursor/backlog strategy.
4. Validate and maintain the 62-screen registry.
5. Continue Phase 1 UI closeout before Phase 2 expansion.
