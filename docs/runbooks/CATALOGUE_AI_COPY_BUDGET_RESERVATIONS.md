# Catalogue AI Copy — server-side request quota candidate

**Status:** Draft code only; no Production migration, Edge deployment, secret change, provider configuration, or paid AI activation is authorized by this document.

This is a deliberately disabled-by-default database reservation gate for the later provider-enabled `catalogue-ai-copy` handler. Source: `20261123062000_catalogue_ai_copy_budget_guard_v1.sql`. Existing Production v45 does **not yet call** this RPC and remains provider-disabled. Do not enable the provider until a separately reviewed Edge version reserves atomically immediately before the OpenAI fetch and fails closed on any denied/error result.

- Requires active internal staff + the existing `ai_studio.ai.use` authority.
- Policy starts `enabled=false` and `approved_model='UNAPPROVED'`.
- Default future quota, only if separately activated: two per user per UTC minute, ten per user per UTC day, forty globally per UTC day, 1,400 maximum requested output tokens.
- One transaction-scoped advisory lock serializes every counter grant; all three counters advance atomically. A failed/aborted provider call consumes its reservation and cannot refund for repeated retries.
- Counters and policy have no anonymous or authenticated direct table access, RLS is enabled. The RPC is authenticated-only.
- Synthetic test identities and policy changes in pgTAP are rolled back.
- **Not a monetary ceiling**: token count, model prices, retry behavior, project billing and input-token usage still need explicit business authorization and provider-side usage/billing limits. Model selection and a controlled spend budget must precede paid activation.
- **Do not ship or turn on** the current v45 provider merely because the database migration passes. A new independently reviewed and protected v45-to-next-version Edge release is needed after the RPC integration and authenticated runtime UAT.

Review focus: migration replay/pgTAP, privilege boundaries, UTC bucketing, advisory-lock contention, direct RPC quota-exhaustion abuse, impact on other AI providers, and governance of policy changes. Separate money-cost telemetry and alerting are required before paid inference.
