# CONNECT-2 — Core Consumer / Channel Contract

**ASM:** ASM-OC-01 — Oasis Connect  
**Programme anchor:** Point 54a  
**Core migration:** `20260922120000_connect2_consumer_channel_authority.sql`  
**Predecessor:** AI Studio CONNECT-1 architecture/census (PR #233)

## Purpose

Implements the narrow Core-owned persistence, authorization, projection and delivery-audit contract for Oasis Connect. AI Studio CONNECT-3 will consume the service-role administration RPCs for configuration UX. Production deployment remains subject to the canonical Task 5 release gate (`T5-WA-001`).

## Reused canonical contracts

| Contract | Usage |
| --- | --- |
| `public.published_products_v1()` | Base customer-safe catalogue projection for `catalogue.products` and `trace.label.fields` |
| `public.buyer_product_prices_v1()` | Precedent only; B2B pricing overlay is **not** activated here (CONNECT-4 dependency) |
| `public.product_pricing_rules` | Unchanged; pricing authority remains Core/Central commercial boundary |
| `public.ols_trace_mutation_receipts` pattern | Idempotency/replay model mirrored by `connect_delivery_log` + advisory locks |
| `trace_approve_reprint_request_v1` | Unchanged; CONNECT-5 must bridge to existing Trace authority |

## New schema objects

| Object | Role |
| --- | --- |
| `connect_consumers` | Stable consumer/application/channel identity |
| `connect_tokens` | SHA-256 hashed bearer tokens, scopes, expiry, revocation |
| `connect_profiles` | Server-governed field/resource allowlists |
| `connect_bindings` | Consumer → profile mapping per environment; at most one active binding per consumer/environment |
| `connect_delivery_log` | Idempotent delivery/audit records (no full payload storage) |

## Public RPC surface

| RPC | Mutating | Grants |
| --- | --- | --- |
| `connect_authorize_and_project_v1(token, resource, params)` | No | `anon`, `authenticated`, `service_role` |
| `connect_record_delivery_v1(token, idempotency_key, resource, response_fingerprint, status, error_category)` | Yes (audit) | `anon`, `authenticated`, `service_role` |

### Supported resources

| Resource | Required scope | Projection source |
| --- | --- | --- |
| `catalogue.products` | `catalogue:read` | `published_products_v1()` + profile field filter |
| `trace.label.fields` | `trace:label:read` | `published_products_v1()` label-safe subset |
| `catalogue.pricing.b2b` | `pricing:b2b` | **Blocked** — raises `CONNECT_PRICING_OVERLAY_PENDING` until CONNECT-4 |

Delivery recording additionally requires `delivery:record` scope.

## Service-role administration RPCs (CONNECT-3 handoff)

| RPC | Purpose |
| --- | --- |
| `connect_admin_register_consumer_v1` | Register consumer identity |
| `connect_admin_issue_token_v1` | Issue scoped token (plaintext returned once) |
| `connect_admin_bind_profile_v1` | Bind consumer to profile in environment |
| `connect_admin_revoke_token_v1` | Revoke bearer token |

## Security summary

- All `connect_*` tables: RLS enabled; **no** direct `anon`/`authenticated` table privileges.
- Token plaintext is never persisted; only SHA-256 digests are stored.
- Privileged RPCs use `SECURITY DEFINER` with fixed `search_path = pg_catalog, public`.
- Field names must match `^[a-z][a-z0-9_]*$`; undeclared fields fail closed.
- Params bounded (`8192` bytes JSON, pagination `limit <= 500`).
- `connect_delivery_log` is append-only (immutable trigger); idempotency keys are scoped per consumer so unrelated consumers cannot collide.
- Consumer, token and binding environments must match; administration and authorization fail closed on cross-environment combinations.

## Reference profiles seeded (templates for CONNECT-3)

- `b2c_india_v1`
- `b2b_india_v1`
- `whatsapp_retail_v1`
- `website_retail_v1`
- `trace_label_v1`

## Central commercial boundary (read-only census)

Central remains the operational/commercial truth owner. Buyer commercial overlays continue through authenticated buyer RPCs such as `buyer_product_prices_v1()` and `customer_sales_order_commercial_facts_v1()`, which require `customer_buyer_eligible_company_id()` — they are **not** suitable for anonymous external bearer tokens without CONNECT-4.

**CONNECT-4 dependency:** Core may expose a governed Central commercial overlay RPC only after Central commercial/customer boundary census completes. CONNECT-2 defines the resource slot (`catalogue.pricing.b2b`) and intentionally fails closed with `CONNECT_PRICING_OVERLAY_PENDING`.

## Adapter handoff contracts

### AI Studio CONNECT-3

- Configure consumers/profiles/bindings via service-role admin RPCs (never store plaintext tokens in AI Studio tables).
- Preview payloads by calling `connect_authorize_and_project_v1` with issued tokens.
- Channel profile UX maps onto seeded `connect_profiles` keys and `allowed_fields`.

### Buyer App / website / WhatsApp adapters

- Obtain bearer token from governed issuance flow.
- Call `connect_authorize_and_project_v1(<token>, 'catalogue.products', …)` for customer-safe catalogue rows.
- Do **not** call `buyer_product_prices_v1()` directly for anonymous website surfaces.
- Record webhook/delivery outcomes via `connect_record_delivery_v1` with stable idempotency keys.

### Trace label bridge (CONNECT-5)

- Use `trace.label.fields` resource with `trace:label:read` scope.
- Physical print/reprint continues through existing `trace_approve_reprint_request_v1` / `ols_reprint_requests` authority — CONNECT-2 does not create parallel printer authority.

## Rollback / recovery

Forward-only migration. Rollback is redeploy-previous-Core + leave new tables unused (no production deployment while Task 5 gate blocks release). If partially applied in non-production, drop functions then tables in reverse dependency order only under governed recovery — do not edit historical migrations.

## Tests

`supabase/tests/connect2_consumer_channel_authority.test.sql` — 43 pgTAP assertions covering the mandated adversarial matrix (token failures, scope isolation, field denial, idempotency, direct table access denial, admin RPC privilege boundary).
