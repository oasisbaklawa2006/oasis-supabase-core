# Edge Function Registry and Configuration Reconciliation

Date: 2026-07-31  
Additive preview update: 2026-08-16  
Procedure: 7 of 8  
Project: `tcxvcatsqqertcnycuop`

## Outcome

Repository registry and deployment configuration are reconciled for the current remediation baseline.

This is a repository-level reconciliation only. It does not assert that all 26 live production functions are safe, captured, deployable, or runtime-certified.

## Configuration baseline

`supabase/config.toml` now declares four approved repository-managed functions for branch/preview deployment:

1. `catalogue-ai-copy` with `verify_jwt = true`.
2. `test-integration` with `verify_jwt = true`.
3. `whatsapp-content-interpret` with `verify_jwt = true`; this is a preview-only, authenticated, read-only WhatsApp interpretation helper pending physical certification and separate production activation approval.
4. `whatsapp-studio-inbox-bridge` with `verify_jwt = false` because it enforces `BRIDGE_CRON_SECRET` in the function body and remains disabled by default.

The following high-risk functions remain intentionally absent from preview configuration:

- `whatsapp-webhook` — failed dedicated certification and remains quarantined.
- `generate-product-attributes` — repository implementation retired; live runtime retirement remains pending.

No broad production Edge Function deployment is permitted.

## Registry reconciliation

The authentication registry continues to account for all 26 live production functions.

`test-integration` and `whatsapp-content-interpret` are repository-managed preview functions and therefore are not added to the 26-function live production inventory. `whatsapp-content-interpret` must remain outside that live registry until a separately approved production activation updates the inventory and runtime certification evidence.

Procedure outcomes reflected in the live registry remain:

- `generate-product-attributes`: repository tombstone present; repository closure complete; runtime removal pending.
- `whatsapp-webhook`: review complete; certification failed; continued quarantine required.
- `whatsapp-studio-inbox-bridge`: repository-certified for controlled manual execution only.
- All uncaptured legacy functions remain explicitly pending rather than being silently classified as safe.

## Source reconciliation alignment

The source reconciliation inventory remains authoritative for production canonical-source presence:

- The prior production reconciliation baseline remains unchanged.
- `whatsapp-content-interpret` is additional repository source for preview certification only and must not be counted as a live production function until approved activation.
- Registry closure status must not be interpreted as production runtime certification.

## Invariants

The following conditions are mandatory:

- Every live production function remains represented in the authentication registry.
- Every production function declared in `supabase/config.toml` must match the live registry.
- Repository-managed preview-only functions may remain outside the live registry only when their source is present, their authentication mode is checked directly, and production activation is explicitly prohibited until certification.
- JWT modes in config must match the applicable registry or preview-only contract.
- `whatsapp-content-interpret` must remain `verify_jwt = true` and preview-only until the physical Hindi/image gate passes and production activation is separately approved.
- `whatsapp-webhook` and `generate-product-attributes` must not be preview-declared.
- Failed, retired, quarantined, partial, pending, preview-only and repository-certified outcomes must remain distinguishable.
- Procedure 8 is the only phase permitted to record runtime certification or production activation evidence.

## Final disposition

Procedure 7 is complete at repository level.

Production deployment, live secret validation, provider callback verification, controlled bridge dry runs and runtime sign-off remain exclusively within Procedure 8. The 2026-08-16 `whatsapp-content-interpret` preview registration does not constitute production activation.
