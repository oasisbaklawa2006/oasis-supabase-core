# Development Engine Takeover Prompt

Use this prompt with a new development engine.

```txt
You are taking over the Oasis Baklawa enterprise software ecosystem. Read `.ai-intent/HANDOVER_INDEX.md` first, then follow the reading order.

Current validated status:
- Legacy WhatsApp webhook is reported restored.
- AI Studio bridge `whatsapp-studio-inbox-bridge` is deployed and working.
- Bridge writes to `whatsapp_inbound_messages`.
- Resolver runs and stores `resolver_result_json`.
- Operator Inbox displays live rows after RLS role mapping fix.
- Operator alternative selection and confirmation work.
- `whatsapp_operator_decisions` and `whatsapp_sales_order_drafts` persist correctly.
- Live Sales Order promotion is not built and must not be assumed.
- Scheduled bridge cron is not enabled.
- Bridge cursor was intentionally advanced near current time to avoid historical backlog flood.

Hard rules:
- Do not deploy or modify `whatsapp-webhook` from AI Studio.
- Do not rebuild working bridge.
- Do not enable scheduled polling until final E2E evidence is recorded and approved.
- Do not paste or store secret values.
- Do not loosen RLS for convenience.
- Do not move to Phase 2 until Phase 1 admin UI stability is closed.

Immediate tasks:
1. Record final fresh post-webhook-recovery E2E evidence in `FINAL_E2E_EVIDENCE_TEMPLATE.md`.
2. Confirm bridge mode: manual development or scheduled polling.
3. Confirm backlog policy: current-only or controlled historical backfill.
4. Validate all 62 screens in `SCREEN_REGISTRY.md`.
5. Continue Phase 1 UI closeout, including AdminFinance z-index cleanup if not already merged.
6. Only then proceed to Phase 2 functional expansion.
```

---

## Mandatory Boundary Files Added After Initial Handover

Before proposing or implementing any code changes, read:

1. `.ai-intent/FEATURE_REGISTRY.md`
2. `.ai-intent/AI_ENGINE_DOS_AND_DONTS.md`
3. `.ai-intent/CURSOR_COST_CONTROL_POLICY.md`
4. `.ai-intent/INDUSTRIAL_GRADE_DELIVERY_POLICY.md`
5. `.ai-intent/QUALITY_GATES_AND_DEFINITION_OF_DONE.md`
6. `.ai-intent/PRODUCT_BUSINESS_EXCELLENCE_POLICY.md`

Do not treat planned, partial, or unknown features as built.
Do not cross repository ownership boundaries without explicit reason and evidence.
Do not touch protected WhatsApp, bridge, RLS, secret, sales order, finance, dispatch, stock, or audit paths without following the guardrails in `AI_ENGINE_DOS_AND_DONTS.md`.
Do not allow Cursor or any AI agent to enter loops, repeat failed fixes, or waste credits; use the stop-loss rules in `CURSOR_COST_CONTROL_POLICY.md`.
Do not mark work complete unless it passes `QUALITY_GATES_AND_DEFINITION_OF_DONE.md`.
Do not build features that lack clear business, usability, management, or operational value.
Always optimize for the smallest safe change that advances the system toward industrial-grade reliability and business usefulness.
