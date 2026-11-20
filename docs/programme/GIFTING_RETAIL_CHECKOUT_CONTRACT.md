# Retail (B2C) checkout — contract, evidence and what is still blocked

Owner direction (19 Nov 2026 IST, Gifting Issue #2 comment 6992883891) approved **items 1, 2, 3 and 6**: one governed Core B2C order surface, Razorpay (India/INR) **sandbox** integration, GST-inclusive display from approved Core settings, and guest checkout with phone OTP and an optional account. Items **4, 5, 7, 8** (shipping/serviceability, refund/cancellation, quote validity and stock reservation, enquiry PII roles/retention) remain **undecided**. This is business direction, not code approval, production deployment approval, live-payment activation or domain cutover.

Code: migration `20261119200000_retail_orders_identity_payments_v1.sql`, edge functions `retail-checkout` and `razorpay-webhook` (candidate sources, `verify_jwt = false`, not deployed), shared modules under `supabase/functions/_shared/`. Stacked on Core #561 (configuration contract).

## What this reuses (no parallel authority)

| Concern | Existing authority used | Not done |
|---|---|---|
| Price | `product_pricing_rules`, channel `retail`, `approved`, `tax_inclusive`, valid dates; product must be in `published_products_v1()` | No price is invented; a product without an approved retail rule is not sellable |
| GST rate | the pricing rule, `products.gst_percentage`, `products.gst_rate` — **all present values must agree and be a recognised percentage** | Disagreement or an unrecognised scale blocks the product (`tax_rate_conflict`) |
| Phone proof | MSG91 verified-widget token, verified by the existing `provider-verify.mjs` and normalised by `strict-phone-match.mjs` | No home-made OTP; no change to `msg91-otp` or the B2B claim bridge |
| Provider events | the append-only / payload-hash / idempotent conventions of `20260907141000` | The B2B `payment_gateway_*` tables are untouched |
| Configuration | `retail_commerce_settings` (Core #561) via `retail_commerce_assert_action_v1` | — |

## Retail identity is not B2B identity

`retail_customers` holds a **verified phone** only. No table in this migration references companies, B2B claims, or any B2B customer table (a pgTAP assertion checks that every foreign key from a `retail_*` table points only to another `retail_*` table or `auth.users`). A retail session is an opaque token (`rsess_…`, only its SHA-256 stored, 12 h, revocable), **not** a Supabase JWT, so it grants nothing in any B2B policy. An account may be linked **optionally** by an authenticated user who presents a live session proving phone control; an account links to at most one customer and a customer to at most one account (conflicts are refused). A linked account can read only its own orders and quotes (RLS); nothing else is readable directly.

## Flow

`POST /retail-checkout/session` (MSG91 access token → session) → `price-display` (GST-inclusive, public) → `quote` → `order` → `payment-intent` (creates the Razorpay sandbox order and associates it) → Razorpay posts a signed webhook to `razorpay-webhook` → order becomes `paid` only when a **verified** event matches the intent's amount and currency.

- Quote: GST-inclusive, per-line GST split (CGST+SGST intra-state, IGST inter-state, from the approved seller state code and the ship-to state), shipping from the approved rate card with its own GST rate, expiry from `quote.validity_minutes`. Idempotent per customer+key (replay 200, different request 409). Records which approvals it relied on.
- Order: one per quote; reservation window from `stock.reservation_minutes`. **The window is recorded; physical stock is not decremented** (`stock_reservation_enforced = false`, enforced by a CHECK).
- Payment intent: amount is derived server-side from the order (paise); `payment.provider` must be approved as `razorpay` (any other approved provider is refused, not rerouted); idempotent per order.
- Webhook: HMAC-SHA256 over the **raw** body with `RAZORPAY_WEBHOOK_SECRET`, constant-time compare; an event id header is mandatory; events are stored durably and applied idempotently (redelivery is a no-op, same id + different payload is a conflict); a captured amount that differs from the intent is stored as `amount_mismatch` and never pays; a late payment is applied and flagged `paid_after_reservation_expiry`; failed/invalid-signature deliveries are logged in an append-only table; database faults return 503 so the provider retries.
- **Live Razorpay keys are refused in code** (`rzp_live_…`). Enabling live mode is a separate approved change.

## Everything is fail-closed

Each action requires its settings **approved with a recorded reference**; otherwise `RETAIL_COMMERCE_BLOCKED`. Specifically: no serviceable PIN list → no quote; no rate card or unmatched slab → `RETAIL_SHIPPING_UNPRICED`; `tax.price_display_mode = exclusive` → refused (only inclusive is implemented); no approved Razorpay provider/settlement ref → no payment; reservation < quote validity → blocked (Core #561 rule). The shipping tables (`retail_serviceable_pincodes`, `retail_shipping_fee_slabs`) are empty and admin-loadable only.

## Evidence

| Evidence | Result |
|---|---|
| pgTAP `retail_orders_identity_payments_v1.test.sql` | 106 assertions, locally on PostgreSQL 16 with a minimal pgTAP shim; **5 of 5 mutants killed** (amount check, customer scope, tax-conflict check, guest-checkout gate, session expiry). Real pgTAP result = Core CI |
| Deno tests (`retailCheckout`, `razorpayWebhook`, `razorpayOrders`) | 31 passed; webhook HMAC and payload hash checked against vectors computed independently with openssl |
| Local sandbox E2E `scripts/uat/retail-checkout-local-sandbox-e2e.ts` | 21/21: real handlers + real PostgreSQL, **fakes for MSG91 and Razorpay**; refuses non-local databases; uses only labelled synthetic settings (`LOCAL-E2E-SYNTHETIC`) |
| Edge registry/config reconciliation, migration governance, base monotonicity | pass locally |

**Not evidence of:** hosted acceptance, a real Razorpay sandbox transaction, MSG91 delivery, or any production behaviour.

## Data defects found while reusing existing authority (Finance/Core data, not decided here)

1. **GST columns disagree in production `products`**: of 337 rows, 116 have `gst_percentage = 5` with `gst_rate = 18`, 14 the reverse, 2 are 12/5, one is on a fractional scale (0.05), and 48 have no `gst_percentage`. Until corrected, those products return `tax_rate_conflict` and cannot be sold. No tax rate or HSN is changed by this work.
2. **Retail price coverage**: production has a single approved GST-inclusive `retail` pricing rule. Every other product is not sellable at retail until Finance approves a rule.

## Hosted sandbox acceptance (cannot be run from the sandbox; requires the owner)

Needs: a Supabase preview/staging project carrying this migration; function secrets `RAZORPAY_KEY_ID` (`rzp_test_…`), `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`, `MSG91_AUTH_KEY`, `RETAIL_ALLOWED_ORIGINS`; a Razorpay **test-mode** webhook pointing at the deployed `razorpay-webhook` with events `payment.captured`, `payment.failed`, `order.paid`; synthetic settings approved by an administrator on that **non-production** project only. Then run the flow above with Razorpay test cards and confirm: order paid by the signed webhook, redelivery changes nothing, a tampered body is rejected (401), and a wrong amount never pays. None of these steps is performed or claimed here.
