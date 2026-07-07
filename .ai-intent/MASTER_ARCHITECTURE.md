# MASTER_ARCHITECTURE.md

# Oasis Enterprise Architecture

## Current Verified Status — 2026-07-06

- `oasis-supabase-core` repository has been created and pushed.
- `oasis-supabase-core` is currently a partial backend extraction: it contains the AI Studio Supabase folder and bridge source, but live Supabase has additional legacy/Central functions not yet imported or ownership-classified.
- Supabase project: `tcxvcatsqqertcnycuop`.
- Manual deployment from `oasis-supabase-core` has been validated for `whatsapp-studio-inbox-bridge`.
- `whatsapp-studio-inbox-bridge` is ACTIVE v17.
- `BRIDGE_CRON_SECRET` has been rotated.
- Dry-run with new bridge secret succeeded.
- `BRIDGE_ENABLED=false` must remain the safe default.
- Legacy `whatsapp-webhook` remains untouched and must not be deployed casually.
- Supabase GitHub integration may point to `oasis-supabase-core`, but production auto-deploy must remain OFF until full backend reconciliation is complete.
- Latest bridge/resolver SQL verification succeeded: message `Hi send 50 kg pyramid` was ingested, `resolver_status=resolved`, `resolver_result_json` populated, `order_quantity=50`, `confidence_band=LOW`, `clarification_required=true`.
- Next technical validation: confirm Operator Inbox UI displays the resolved low-confidence/clarification row.


## 1. Ecosystem Framework

The Oasis Baklawa software ecosystem is a model-agnostic enterprise workspace made of four repositories:

1. `oasis-supabase-core` — canonical backend authority.
2. `oasis-baklawa-central` — Central ERP/admin operations frontend.
3. `oasis-ai-studio` — catalogue/product intelligence frontend.
4. `oasis-trace` — labelling, barcode, printer, and traceability frontend.

The total planned product scope is 62 screens across these applications. The shared backend database coordinates product truth, order truth, warehouse execution, finance gates, dispatch gates, labels, and WhatsApp/AI ingestion.

## 2. Repository Ownership

### Backend Authority

`oasis-supabase-core` owns:

- Supabase migrations.
- Edge functions.
- RPCs.
- RLS policies.
- Storage policies.
- Supabase config.
- Backend deployment runbooks.
- Shared backend runtime code.

Frontend repositories must not own deployable Supabase infrastructure.

### Frontend Applications

Frontend apps may contain:

- UI routes.
- Client code.
- API clients.
- Generated types.
- Application-specific UI state.

Frontend apps must not casually deploy:

- `supabase/functions`
- `supabase/migrations`
- `supabase/config.toml`

## 3. Unified Auth Infrastructure

The long-term auth layer must support:

- Apple Login.
- Google Login.
- Passkeys.
- OTP verification via msg91.
- Internal staff roles.
- Department-based permissions.
- Admin/manager approvals.
- Data-level access control.

Every user must resolve to one internal identity that can carry app memberships, role memberships, approval authority, and audit identity.

## 4. System Gates

### Phase 1 — UI/UX Stability Gate

Before deeper dependency expansion, all admin screens must be stable:

- No modal/z-index collisions.
- No route loading failure.
- No scroll trap.
- No hidden admin action.
- No role leakage.
- No mobile/tablet layout breakage in critical admin screens.

### Phase 2 — Functional Dependency Expansion

Only after Phase 1:

- Golden Pipeline expansion.
- Department KOT.
- Finance batch operations.
- Dispatch foundation.
- Final invoice.
- Warehouse segmentation.
- Gatekeeper.
- Labelling integration.
- WhatsApp-to-order completion.

## 5. Golden Pipeline

The Golden Pipeline is the canonical state machine for order flow:

1. Customer/order intake.
2. Product resolution.
3. Quantity interpretation.
4. Sales order creation.
5. Proforma invoice generation.
6. Payment verification.
7. Finance approval.
8. Warehouse allocation.
9. Packing/assembly.
10. Ready goods staging.
11. Dispatch planning.
12. Label generation.
13. Gatekeeper verification.
14. Invoice/e-way bill finalization.
15. Dispatch completion.
16. Audit closure.

No frontend click may bypass backend validation gates.

## 6. Cross-App Boundaries

- Central owns operations, orders, warehouse, dispatch, finance, approvals.
- AI Studio owns catalogue truth, media, aliases, resolver data, catalogue PDFs.
- Labelling owns physical labels, barcodes, printer layouts, label audit.
- Supabase Core owns database, functions, policies, migrations, and backend runtime.

## 7. Non-Negotiable Rules

1. Do not deploy `whatsapp-webhook` casually.
2. Keep Supabase production auto-deploy OFF until full backend reconciliation.
3. Do not enable bridge cron until Operator Inbox UI validation passes.
4. Do not move an AI result into operational truth without persistence, confidence, and review.
5. Do not let a frontend repo become the backend authority.
6. Do not delete legacy frontend `supabase/` folders until build validation and backend reconciliation are complete.
