# Oasis Appverse — Live System Inventory

Certification mission started: 2026-09-15 (Asia/Kolkata)

## Evidence hierarchy

Current code, exact repository HEADs, GitHub Actions, live Supabase read-only evidence, deployed runtime metadata, then historical handovers.

## Repositories in active certification scope

| System | Repository | Exact main HEAD at discovery | Initial evidence state |
|---|---|---|---|
| Supabase Core | `oasisbaklawa2006/oasis-supabase-core` | `6d782c5a4a542f5b07f3915b85d94e48a8a9e053` | exact-head workflows green; independent DB/security certification in progress |
| B2B Buyer App | `oasisbaklawa2006/oasis-baklawa` | `dd620ad59b351fb4bd075e2450e44a89db181d20` | scheduled golden-path workflow green; adversarial certification in progress |
| Central | `oasisbaklawa2006/Oasis-Baklawa-Central` | `3f9399b64edabddee8bc77ceb2370f3e88d0a202` | exact-head workflows green; route/RBAC/state certification in progress |
| AI Studio | `oasisbaklawa2006/oasis-ai-studio` | `12d7b8d489a57da702d4e39648bb3443e85ed528` | exact-head workflows green; one open CORS/security PR remains unmerged |
| Trace | `oasisbaklawa2006/oasis-trace` | `894f27327381ce168d168530eba3c3722d71eaee` | discovery in progress |
| Legacy ERP integration | `oasisbaklawa2006/erp.oasisbaklawa.com` | discovery pending | included where it remains an integration authority |
| Shared contracts | `oasisbaklawa2006/oasis-appverse-contracts` | repository surfaced by repository census; direct ref access pending | discovery pending |
| Company OS | `oasisbaklawa2006/OASIS-COMPANY-OS` | repository surfaced by repository census; direct ref access pending | discovery pending |

## Production backend

Canonical Supabase project: `tcxvcatsqqertcnycuop` (`oasis-baklawa`, ap-south-1), status `ACTIVE_HEALTHY` at discovery.

Read-only database census at 2026-09-15T05:14:32Z:

- Public base tables: 349
- Public views: 35
- Public routines: 611
- Public RLS policies: 600
- Applied migrations: 405
- Latest applied migration: `20260914160000`
- B2B access applications: pending 5, approved 47, rejected 6
- `whatsapp_inbound_messages`: pending 211, resolved 82, failed 5

Deployed Edge Functions: 33 active functions were discovered. JWT policy and custom-auth review is tracked separately in the security registry.

## Current release truth

Historical certification statements are not accepted unless they bind to the exact current HEAD/deployment. Current exact-head CI is evidence only for the invariants it actually executes; it is not itself full-system certification.

## Safety mode

Production is read-only for this mission unless an already-approved isolated reversible test mechanism is proven. Destructive/consequential tests must use test fixtures, preview, staging, transaction rollback, or remain `BLOCKED_EXTERNAL`.
