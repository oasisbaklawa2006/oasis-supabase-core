# Catalogue AI Copy — monetary budget reservation (APPVERSE-CORE-AI-BUDGET-01)

**Status:** code only. This runbook does not authorise a production migration, an Edge deployment, installing the OpenAI key or any paid inference. Parent dependency: `APPVERSE-AI-FINAL-01`. Owner approval and Revision 3 are recorded on Central issue #437. Supersedes the never-deployed request-count candidate (`20261123062000`, closed PR #597, commit `ea93ce21`, preserved in branch history).

## Policy (owner-approved; CHECK-bounded in `catalogue_ai_copy_budget_policy_v1`, disabled by default)

| Setting | Value |
|---|---|
| Model | `gpt-5.4-mini-2026-03-17` (pinned; never substituted) |
| Prices | $0.75 / 1M input tokens, $4.50 / 1M output tokens (cached discount ignored) |
| Limits per request | 8,000 input tokens (official count), 1,400 output tokens (incl. reasoning), 15,000 micro-USD maximum reservation |
| Company | 5,000,000 micro-USD per UTC day, 50,000,000 per UTC month |
| Per user | 1,000,000 micro-USD and 100 requests per UTC day; 5 requests per UTC minute |
| Inference | `service_tier="default"`, `reasoning.effort="none"`, no tools, no retry, no fallback |

Worst case at the approved prices is 8,000 x 0.75 + 1,400 x 4.5 = 12,300 micro-USD, covered by the 15,000 reservation (enforced by a table CHECK). No function can raise a limit; a later increase needs a reviewed migration.

## Request flow (every step fails closed)

authenticated staff (`ai_studio.ai.use`) -> `catalogue_ai_copy_budget_gate_v1` (rate slot, before any provider call) -> serialized-body ceiling (8,000 bytes, defensive) -> official `POST /v1/responses/input_tokens` on the same model/input/schema/reasoning -> `catalogue_ai_copy_budget_reserve_v1` (user + company limits in one transaction) -> ONE inference call -> `catalogue_ai_copy_budget_settle_v1` (idempotent; charge = verified usage, never below it) or `catalogue_ai_copy_budget_mark_ambiguous_v1` (full reservation kept, never auto-released).

Tripwires (provider input above the official count, output above the cap, response model or service tier different, charge above reservation) withhold the content and set the emergency latch, except as stated below for an unverifiable model or tier mismatch. A different response model or service tier keeps the FULL reservation (it cannot be priced at the approved rates); the other tripwires settle at verified usage. For a model or tier mismatch with unverifiable usage, the Edge guard only ATTEMPTS to set the latch through `catalogue_ai_copy_budget_emergency_disable_v1` (best-effort). If that call fails, the latch is not set and inference stays enabled until the budget caps are reached; the full reservation stays held. Operators must then call `catalogue_ai_copy_budget_emergency_disable_v1` with `service_role` or turn off `AI_STUDIO_AI_ENABLED`. `catalogue_ai_copy_budget_emergency_disable_v1` also sets it. Nothing clears the latch or raises a limit; re-enabling is a reviewed migration or governed owner procedure. `AI_STUDIO_AI_ENABLED` remains an independent second kill switch.

All five RPCs are `SECURITY DEFINER`, `search_path = ''`, executable by `service_role` only. No API role has direct table privileges.

## Verification

- pgTAP `20261126060000_catalogue_ai_copy_budget_reservation_v1.sql` (permissions, ceilings, boundaries, exhaustion, duplicate settlement, UTC rollover, ambiguity, tripwires).
- `deno test` `catalogueAiCopyBudget.test.ts` (ordering, zero provider call on every failure path, no retry, static check that the paid fetch is reachable only through the guard).
- `scripts/tests/verify-ai-copy-budget-concurrency.sh` against a disposable local database (parallel sessions race for room for exactly three reservations).

## Provider-side exposure (read before activation)

The $5/day, $50/month and per-user figures are **internal Core accounting limits**, not a guaranteed ceiling on what the provider actually bills. Internal reservation caps **cannot absolutely guarantee provider-side spending limits**. Spend can exceed the internal ledger, and therefore the stated $5 daily figure, if:

- the provider changes prices, bills a component not modelled here, or applies a different rate than the policy prices;
- the provider serves a different model or service tier than the pinned snapshot (the response is detected only AFTER the call; the settlement keeps the full reservation and sets the emergency latch, but requests already in flight when the latch trips are not recalled);
- several requests are in flight at once, or a provider response is lost so usage is never verified (the full reservation is then kept, which is an estimate, not the provider's invoice).

Controls that reduce, but do not eliminate, this exposure: the pinned model snapshot and explicit `service_tier="default"`; `reasoning.effort="none"` and the 1,400-token output cap; the 8,000-token official input count; the 5 requests per user per minute and per-user daily limits; the strict tripwire (provider input tokens above the official count, a different response model or tier (full reservation kept), or an output above the cap (settled at verified usage) trips the emergency latch); and the manual emergency latch plus the independent `AI_STUDIO_AI_ENABLED` switch.

The strict token-count tripwire is intentionally retained: provider-reported input tokens that exceed the official count, however slightly, disable inference until a reviewed migration or governed owner procedure re-enables it. Expect the canary to stop on a one-token excess; that is the safe outcome, not a defect.

Required owner-side backstop (outside this repository): set a hard spend limit and usage alerts on the OpenAI project that owns the restricted key, and reconcile the provider's usage dashboard against `catalogue_ai_copy_reservations_v1` after the canary and on a regular schedule.

## Activation order (separate owner gates; do not skip)

1. Governed migration, then governed Edge deployment, with the policy DISABLED and `AI_STUDIO_AI_ENABLED` unset.
2. Independent verification of the deployed safeguards.
3. Owner decision to install the restricted OpenAI key.
4. Count-only commissioning (free): confirm key permissions for `/v1/responses/input_tokens` and `/v1/responses`, snapshot access and counting accuracy.
5. Supervised canary: through a governed step set `AI_STUDIO_AI_ENABLED=true` (it stays UNSET during deployment and count-only commissioning, otherwise the handler returns 503 before any reservation) and enable the database policy; run one reserved inference, verify settlement and tripwire fields, then certification.

Image generation, photography enhancement and bulk processing are outside this budget.
