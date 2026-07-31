# Edge Function Registry and Configuration Reconciliation

Date: 2026-07-31
Procedure: 7 of 8
Project: `tcxvcatsqqertcnycuop`

## Outcome

Repository registry and deployment configuration are reconciled for the current remediation baseline.

This is a repository-level reconciliation only. It does not assert that all 26 live production functions are safe, captured, deployable, or runtime-certified.

## Configuration baseline

`supabase/config.toml` declares exactly three approved repository-managed functions:

1. `catalogue-ai-copy` with `verify_jwt = true`.
2. `test-integration` with `verify_jwt = true`.
3. `whatsapp-studio-inbox-bridge` with `verify_jwt = false` because it enforces `BRIDGE_CRON_SECRET` in the function body and remains disabled by default.

The following high-risk functions remain intentionally absent from preview configuration:

- `whatsapp-webhook` — failed dedicated certification and remains quarantined.
- `generate-product-attributes` — repository implementation retired; live runtime retirement remains pending.

No broad Edge Function deployment is permitted.

## Registry reconciliation

The authentication registry continues to account for all 26 live production functions.

Procedure outcomes now reflected in the registry:

- `generate-product-attributes`: repository tombstone present; repository closure complete; runtime removal pending.
- `whatsapp-webhook`: review complete; certification failed; continued quarantine required.
- `whatsapp-studio-inbox-bridge`: repository-certified for controlled manual execution only.
- All uncaptured legacy functions remain explicitly pending rather than being silently classified as safe.

## Source reconciliation alignment

The source reconciliation inventory remains authoritative for canonical-source presence:

- 4 repository sources are present.
- 22 production functions remain unresolved or uncaptured.
- Registry closure status must not be interpreted as production runtime certification.

## Invariants

The following conditions are mandatory:

- Every live production function remains represented in the authentication registry.
- Every function declared in `supabase/config.toml` must exist in the registry.
- JWT modes in config must match the registry.
- `whatsapp-webhook` and `generate-product-attributes` must not be preview-declared.
- Failed, retired, quarantined, partial, pending and repository-certified outcomes must remain distinguishable.
- Procedure 8 is the only phase permitted to record runtime certification or production activation evidence.

## Final disposition

Procedure 7 is complete at repository level.

Production deployment, live secret validation, provider callback verification, controlled bridge dry runs and runtime sign-off remain exclusively within Procedure 8.
