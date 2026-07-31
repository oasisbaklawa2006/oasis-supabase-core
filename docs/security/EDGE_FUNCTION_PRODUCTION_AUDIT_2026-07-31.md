# Edge Function Production Audit — 2026-07-31

Project: `tcxvcatsqqertcnycuop`

## Scope

This audit compares the live Supabase Edge Function inventory with canonical Core ownership, repository source, authentication mode, deployment controls, and documented operational intent.

## Live inventory summary

Production currently reports 27 ACTIVE Edge Functions. The repository registry previously documented only a small subset, so repository/live drift is a release blocker until each live function is assigned an owner and canonical source.

## Immediate security classifications

### Quarantined

- `generate-product-attributes` — live with `verify_jwt=false`; generates nutrition, allergens, HSN and GST through an AI model without verified compliance sources. It must not be auto-deployed or treated as authoritative. Replacement must be authenticated, draft-only, source-backed and human-approved.

### High-risk dedicated deployment only

- `whatsapp-webhook` — public Meta callback with custom provider verification. Never deploy through broad preview automation.
- `whatsapp-studio-inbox-webhook` — public Studio ingress/test harness; custom authentication and exact purpose must be revalidated.
- OTP/provider callbacks (`whatsapp-otp`, `msg91-otp`, `msg91-webhook`) — public by protocol; require provider signature/secret, replay protection, rate limits and redacted logs.

### Custom-auth controlled services

- `whatsapp-studio-inbox-bridge` — `verify_jwt=false` is intentional only because `BRIDGE_CRON_SECRET` is checked in code. `BRIDGE_ENABLED=false` remains the default.

### JWT-required user/admin services

The following classes must use platform JWT or equivalent strict token validation and role checks: admin mutations, operator replies, outbound messaging initiated by users, AI studio actions, barcode/scan submissions, integration diagnostics and internal automation controls.

## Confirmed repository/production drift

- The live `generate-product-attributes` implementation differs materially from the repository implementation.
- Production has many functions not represented by the earlier five-function repository inventory.
- `supabase/config.toml` previously declared no functions, so preview success did not prove Edge Function deployment coverage.

## Release gates

1. Inventory every live function with owner, caller, auth mechanism, secrets, data writes and rollback procedure.
2. Capture the live source checksum and compare it with canonical repository source.
3. No broad function deployment command is permitted.
4. Every deploy must name one function explicitly and use the reviewed `verify_jwt` mode.
5. Public protocol endpoints require custom authentication, replay protection, rate limiting and safe logging.
6. Service-role use must be justified and isolated to server-only code.
7. Functions that mutate commercial truth require idempotency and an auditable authority check.
8. Quarantined functions cannot be promoted by preview or production workflows.
9. Secrets are verified by name/presence only; values never enter repository, logs or evidence.
10. Production deployment requires post-deploy health evidence and rollback notes.

## Database-wide follow-on findings

The Supabase security advisor is not clean. Current findings include RLS-enabled tables without policies, broadly permissive write policies, public bucket listing, executable SECURITY DEFINER functions, `pg_net` in `public`, and leaked-password protection disabled. These findings require separate migration tranches and contract tests; they must not be mass-edited directly in production.
