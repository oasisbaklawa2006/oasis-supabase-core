# Gifting retail commerce — configuration decision sheet

**Status: PENDING OWNER APPROVAL. Nothing here is approved, active or implemented as a policy.** The configuration
infrastructure (Core `20261119020200_retail_commerce_configuration_v1.sql`) is ready to hold these values; until each
required value is **approved by an administrator with a recorded reference**, the action that depends on it stays blocked.
Checkout stays held regardless.

> **Update 19 Nov 2026 (owner direction, Issue #2 comment 6992883891):** items 1, 2, 3 and 6 are approved as *direction*
> (one Core B2C order surface; Razorpay INR sandbox; GST-inclusive display; guest + phone OTP, optional account). That is
> not a recorded approval of any setting below: each setting still needs an administrator's approval with a reference
> before its action unblocks. Items 4, 5, 7, 8 remain undecided. See `GIFTING_RETAIL_CHECKOUT_CONTRACT.md`.

How to read the **State** column
- **Missing** — no value exists anywhere I could read. A decision or data is needed.
- **Candidate (published copy)** — customer-facing text already published on the website. It is a strong candidate but it is
  website copy, not an approved configuration; the owner confirms it.
- **Fixture (not approved)** — a placeholder in website code (`src/data/*`), explicitly mock. Do not treat as policy.
- **Existing authority** — recorded in Core's master data.
- **Derived** — inferred from a published fact; the owner confirms it.

Sources searched (authorised, read-only): Gifting `main` (`src/data/checkout.ts`, `src/data/shipping.ts`, returns/terms pages),
Core source and migrations, **production Core** (SELECT only: tax columns, published products, table inventory, migration
ledger), Central programme register. Production Core has **no** shipping, serviceability, refund or tax-rule tables.

## A. Gates

| # | Setting key | Needed for | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|---|
| 1 | `architecture_approved` | every action | none | Missing | Does the Gifting site share the Customer App order surface (Central register 100d–f) instead of a website-specific commerce path? | **Yes — one B2C order surface**; avoids a second price/order authority |
| 2 | `activation_enabled` | every action | none | Missing | Separate go-live switch | **Keep off** until sandbox UAT passes and the owner signs off |

## B. Payment

| # | Setting key | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|
| 3 | `payment.provider` (`razorpay` / `cashfree` / `payu` / `stripe`) | Core payment intents already model `razorpay, payu, cashfree, stripe, generic` (for B2B orders); the website webhook verifies Razorpay and Stripe signature formats | Missing (capability exists) | Which provider | **Razorpay** (INR, India) |
| 4 | `payment.settlement_account_ref` | none | Missing | Which settlement account record (a reference id, never account numbers) | Finance to name it |

## C. Tax

| # | Setting key | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|
| 5 | `tax.price_display_mode` (`inclusive` / `exclusive`) | none; website prices are fixtures | Missing | Show prices GST-inclusive or exclusive | **Inclusive** (B2C India norm) |
| 6 | `tax.seller_state_code` (2 digits) | Website footer: "10/62 Kirti Nagar Industrial Area, New Delhi 110015" → Delhi = `07` | Derived | Confirm the state of the supplying GST registration (GSTIN) | `07` if the GSTIN is Delhi-registered |
| — | GST rate and HSN per product | **Core `products.gst_rate` / `hsn_code`**: all 8 published products have both | **Existing authority — with a defect** | Normalise the rate scale. The 8 products store rates on **two scales** (`5` and `0.05`); a tax engine cannot assume one | Core data task: pick percent or fraction, normalise, add a check constraint. No decision value needed from the business |

## D. Shipping and serviceability

| # | Setting key | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|
| 7 | `shipping.model` (`flat` / `slab` / `free_above`) | Website fixture: standard fee 149, free above 2500; express 349; other levels 499 / 699 (all "mock amount, INR") | Fixture (not approved) | Charge model | **Slab with serviceable-PIN allowlist** |
| 8 | `shipping.fee_table_ref` | none (no rate card) | Missing | Approved rate card version | Operations to supply |
| 9 | `shipping.serviceable_pin_policy_ref` | Website `shippingZones` PIN-prefix routing table is a mock; Core has no serviceability table | Missing | Approved serviceable PIN list | Operations to supply |
| 10 | `shipping.free_above_amount_inr` (only for `free_above`) | Fixture 2500 | Fixture (not approved) | Threshold | Business to set |
| 11 | `shipping.delivery_promise_days` | Fixture: standard "2–5 working days", express "1–2" (placeholders) | Fixture (not approved) | Promise for perishable gifts | Operations to set |

## E. Refunds and cancellation

| # | Setting key | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|
| 12 | `refund.window_hours` | Published returns page: damaged or incorrect items must be reported **within 48 hours of delivery** | Candidate (published copy) | Confirm 48 | **48** |
| 13 | `refund.method` | Published: approved refunds go **to the original payment method** | Candidate (published copy) | Confirm | `original_payment` |
| 14 | `refund.approver_role` (`finance` / `admin` / `super_admin`) | none | Missing | Who approves | **Finance** |
| 15 | `refund.perishable_policy_ref` | Published: no returns of delivered sweets/chocolates/dates; change or cancel only before packing; refused or undeliverable perishables are not re-dispatched | Candidate (published copy) | Confirm the published text is the policy and name its version | Reference the published returns page version |

## F. Checkout, quote and stock

| # | Setting key | Existing value & source | State | Decision | Recommendation |
|---|---|---|---|---|---|
| 16 | `checkout.guest_allowed` | none | Missing | Guest checkout or login required | **Guest with phone OTP at order**, account optional (Core's existing MSG91 OTP bridge is B2B-claim based, so a D2C identity decision is needed) |
| 17 | `quote.validity_minutes` (1–120) | none (no precedent in Core) | Missing | Minutes a quote stays valid | Value to be supplied |
| 18 | `stock.reservation_minutes` (1–180, **must be ≥ quote validity**) | none | Missing | Minutes stock is held after a quote is accepted | Value to be supplied |

## G. Related decisions that are not settings

| # | Item | State | Recommendation |
|---|---|---|---|
| 19 | Roles allowed to read D2C enquiry personal data (Core #559 is admin / super_admin only) | Missing | Keep admin-only until named; widening is a one-function change |
| 20 | Retention / anonymisation period for closed and spam enquiries | Missing | Owner/legal to set N days |
| 21 | Persistent Core staging project instead of the temporary preview branch (Core #495) | Missing | Mission Control to name one |
| 22 | Netlify project `oasisbaklawa` building this repository, and the public repository | Intent unknown | Owner to confirm or restrict |
| 23 | Wix source site (`880c7f4f…` is the only Premium + custom-domain + Stores V3 site) | Derived | Owner to confirm |

## Summary
- **Existing authoritative values recovered:** GST rate and HSN for the 8 published products (with the scale defect above).
- **Candidates from published copy, to confirm:** refund window (48 h), refund method (original payment), perishable rules, and the
  Delhi state code derived from the published address.
- **Fixtures, explicitly not policy:** every shipping fee, threshold and transit window currently in website code.
- **Genuinely missing (no value anywhere):** payment provider and settlement reference, price display mode, rate card,
  serviceable PIN policy, refund approver, guest checkout, quote validity, stock reservation, and the two gates.

Reply format: one line per number, e.g. `1 yes · 3 razorpay · 5 inclusive · 12 48 · …`. Approving means an administrator
records each value in Core with a reference through `retail_commerce_set_setting_v1`; nothing is applied by replying here.
