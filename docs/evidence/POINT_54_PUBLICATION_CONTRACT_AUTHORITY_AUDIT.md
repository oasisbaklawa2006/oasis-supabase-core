# Point 54 — Publication Contract Canonical Authority Audit

**Workstation:** Core #194 (immutable original Point 54)  
**Census head:** `049950fb5f7c681c5cbcc58f0d2d7825075a52d7` (`main` at audit time)  
**Production project:** `tcxvcatsqqertcnycuop`  
**Verdict:** Core publication **read contract is production-complete**. No append-only migration delta required. Historical Central #459 `BLOCKED` classification for Point 54 is **stale** and is a safe strike candidate for reconciliation to **COMPLETE** (contract slice only).

## Authority matrix

| Dimension | Canonical authority | Evidence |
|---|---|---|
| **Source product/draft truth** | `public.catalogue_product_drafts` → governed approval RPCs → `public.products` | `approve_catalogue_product_draft(uuid)`, `approve_catalogue_draft_internal(text, uuid)`, `catalogue_approve_product_draft_atomic_v1(...)` (Point 29 hardening, migrations `20260904030100`, `20260904030200`) |
| **Approval prerequisite** | `public.is_catalogue_reviewer()`; draft `status = 'pending_approval'`; allowed draft tables enumerated in `approve_catalogue_draft_internal` | Baseline `20260723161256_legacy_role_authority_baseline.sql`; Point 29 pgTAP `point29_atomic_intake_barcode_authority.test.sql` |
| **Publication command / RPC** | **No dedicated publish/unpublish RPC.** Publication is expressed as persisted boolean gates on `public.products` (`is_active`, `visible_in_catalog`, `is_catalogue_ready`). Product approval intentionally creates with `visible_in_catalog = false`; `is_catalogue_ready` defaults `false`. | Approval insert path in baseline + Point 29 atomic approval. Programme Points **55** (Central operational publish) and **56** (Buyer customer-safe publish) own consumer-specific publish flows. |
| **Persisted publication state** | `public.products.is_active`, `public.products.visible_in_catalog`, `public.products.is_catalogue_ready` | Column definitions in baseline; approval path sets `is_active=true`, `visible_in_catalog=false` on create |
| **Published projection / view** | `public.published_products_v1()` — `SECURITY DEFINER`, fixed `search_path`, stable SQL function | Baseline `20260723161256`; compatibility stubs `20260721191444`, `20260722193000` |
| **Customer-safe field allowlist** | Projection columns only: `product_id`, `sku`, `product_name`, `short_description`, `long_description`, `category`, `subcategory`, `hero_image_url`, `pack_size`, `storage_type`, `shelf_life`, `shelf_life_days`, `dietary_tags`, `allergen_warnings`, `primary_uom`, `created_at`. Excludes pricing, cost, MOQ, operational and draft-only fields per function comment. | Function body baseline lines ~2706–2740 |
| **Unpublish / correction semantics** | Unpublish = clear one or more publication gates on `public.products` (product drops out of `published_products_v1()`). Corrections to approved truth use governed draft resubmit + `approve_catalogue_*` update path; does not auto-republish. | Projection filter is conjunctive; approval audit retained in `public.catalogue_approval_audit` |
| **Idempotency / version / audit evidence** | Draft approval: status-guarded (`pending_approval` only); `catalogue_approval_audit` stores `before_snapshot` / `after_snapshot` / `payload_snapshot`. Publication gate mutation: **no dedicated publication audit table or idempotent publish RPC** (deferred to Points 55–56). | `catalogue_approval_audit` in baseline; Point 29 audit assertions in pgTAP |
| **Central consumer** | Reads `published_products_v1()` for customer-safe catalogue projection; operational product truth remains `public.products` behind team/admin authority. Legacy `public.catalogues` publish workflow exists only in archived pre-baseline migrations, not active contract. | Central register doc `APP_VERSE_POINT_2_REPOSITORY_STATE_AND_DEDUPLICATION_2026-07-23.md` credits production `published_products_v1` |
| **Buyer consumer** | `buyer_product_prices_v1()` joins `published_products_v1()`; `customer_company_product_price_v1(...)` and checkout/order RPCs (`20260807171000_customer_order_draft_v1.sql`) enforce published-product membership before commercial facts | pgTAP: `published_products_v1_contract.sql`, `buyer_product_prices_v1_contract.sql`, `20260807171000_customer_order_draft_v1_contract.sql`, APP-E2E buyer suites |
| **Current gaps (out of Point 54 contract scope)** | (1) No governed `publish_product_v1` / `unpublish_product_v1` RPC with publication audit — **Point 55/56**; (2) `is_catalogue_ready` has no governed setter in active migrations — operational publish lane; (3) `OASIS_ADMIN_FULL_CONTROL` on `public.products` is permissive for direct gate mutation — future governance hardening, not projection contract | See programme ledger Points 55–56 in Central #459 |

## Publishability gate (canonical)

A product is publishable **iff** all hold:

```sql
p.is_active IS TRUE
AND p.visible_in_catalog IS TRUE
AND p.is_catalogue_ready IS TRUE
AND nullif(btrim(p.sku), '') IS NOT NULL
AND coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), '')) IS NOT NULL
```

Enforced exclusively by `published_products_v1()` (not by unconstrained `SELECT` on `public.products`).

## Production deployment evidence

| Artifact | Value |
|---|---|
| Production migration versions | `20260721191444` (ledger), `20260722193000` (post-baseline ledger), schema effect in `20260723161256` |
| Companion buyer contract migrations | `20260721191841`, `20260722210000`, `20260722223000` |
| Production release smoke | `.github/workflows/production-migration-release.yml` requires `published_products_v1()` at deploy |
| Production ledger CSV | `docs/reconciliation/production-migration-ledger-2026-07-25.csv` rows 153+; post-baseline ledger row 2 |
| Introducing commits | `de9b418` (projection), `96c7c7c` (pgTAP contract) |

## Local verification (audit run)

```text
HEAD: 049950fb5f7c681c5cbcc58f0d2d7825075a52d7
Command: bash scripts/verify-local-schema-release-readiness.sh
Result: SUCCESS — 196 pgTAP files, 2926 tests PASS
Including: supabase/tests/published_products_v1_contract.sql (8 tests PASS)
```

## #459 strike reconciliation recommendation

| Point | Prior (#459 context) | Recommended status | Rationale |
|---|---|---|---|
| **54 — Publication contract** | `BLOCKED` (predates Point 29 production release) | **COMPLETE** (Core contract slice) | Production-deployed `published_products_v1()` + pgTAP + buyer composition + production smoke. Approval/publication separation is intentional. |
| **55 — Publish operational data Central** | — | **NOT STARTED / IN PROCESS** (Central-owned) | No governed Core publish command RPC |
| **56 — Publish customer-safe data Buyer** | — | **IN PROCESS** | Buyer reads governed projections; publish gate mutation path not hardened |

**Safe strike:** Remove Point 54 from `BLOCKED` in Central #459 ledger; mark **COMPLETE** with evidence anchors above. Do **not** strike Points 55–56.

## Dependency map

```text
catalogue_product_drafts
  └─ submit_catalogue_product_draft_v1 / contributor insert
  └─ approve_catalogue_product_draft → catalogue_approve_product_draft_atomic_v1
       └─ public.products (master truth; not yet customer-visible)
            └─ [operational publish: visible_in_catalog + is_catalogue_ready]  ← Points 55/56
                 └─ published_products_v1()  ← Point 54 contract (THIS)
                      ├─ buyer_product_prices_v1()
                      ├─ customer_company_product_price_v1()
                      └─ customer_order_draft / checkout submit guards
```

## Boundaries preserved

- No overlap with WhatsApp media #188
- No alteration to Point 29 barcode authority (`catalogue_claim_intake_barcode`, `barcode_sku`)
- No customer-visible commercial truth invented
- No production schema writes performed in this audit
- No append-only migration added (contract already deployed)

## Stop condition

Audit complete. **No Core migration PR required.** Stop before merge/production approval of any new contract delta. Downstream Central/Buyer publish-lane hardening proceeds under Points 55–56 after Mission Control reassignment if needed.
