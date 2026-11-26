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

Tripwires (provider input above the official count, output above the cap, response model or service tier different, charge above reservation) settle at verified usage, withhold the content and set the emergency latch. `catalogue_ai_copy_budget_emergency_disable_v1` also sets it. Nothing clears the latch or raises a limit; re-enabling is a reviewed migration or governed owner procedure. `AI_STUDIO_AI_ENABLED` remains an independent second kill switch.

All five RPCs are `SECURITY DEFINER`, `search_path = ''`, executable by `service_role` only. No API role has direct table privileges.

## Verification

- pgTAP `20261126060000_catalogue_ai_copy_budget_reservation_v1.sql` (permissions, ceilings, boundaries, exhaustion, duplicate settlement, UTC rollover, ambiguity, tripwires).
- `deno test` `catalogueAiCopyBudget.test.ts` (ordering, zero provider call on every failure path, no retry, static check that the paid fetch is reachable only through the guard).
- `scripts/tests/verify-ai-copy-budget-concurrency.sh` against a disposable local database (parallel sessions race for room for exactly three reservations).

## Activation order (separate owner gates; do not skip)

1. Governed migration, then governed Edge deployment, with the policy DISABLED and `AI_STUDIO_AI_ENABLED` unset.
2. Independent verification of the deployed safeguards.
3. Owner decision to install the restricted OpenAI key.
4. Count-only commissioning (free): confirm key permissions for `/v1/responses/input_tokens` and `/v1/responses`, snapshot access and counting accuracy.
5. Supervised canary: enable the policy, one reserved inference, verify settlement and tripwire fields, then certification.

Image generation, photography enhancement and bulk processing are outside this budget.
