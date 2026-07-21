# Oasis App-Verse Repository Ownership Matrix

Status: Draft architecture contract

This document assigns one primary owner to each business capability. It is documentation only and does not change application, database, policy, deployment, or production behavior.

## Ownership rules

1. Every capability has one primary repository owner.
2. Other applications may consume governed read contracts, commands, or events but must not create a competing source of truth.
3. Production schema evolution belongs only to `oasis-supabase-core`.
4. Frontends must not gain authority merely because they can reach a shared Supabase project.
5. Existing duplicated behavior is transitional debt, not accepted permanent ownership.

## Repository responsibilities

| Domain / capability | Primary owner | Allowed consumers | System of record | Prohibited duplicate ownership |
|---|---|---|---|---|
| Public storefront and brand discovery | `oasis-baklawa` | Central may deep-link | Published read models | Central must not remain the permanent public storefront |
| Buyer registration and onboarding UX | `oasis-baklawa` | Central staff review | Canonical identity/company records | AI Studio and Trace must not own buyer onboarding |
| Buyer account, addresses, favourites and documents | `oasis-baklawa` | Central customer service | Canonical buyer/company records | Trace must not write customer profile truth |
| Cart, quick order and order intent | `oasis-baklawa` | Central receives submitted intent | Canonical order-intent/order records | Customer App must not approve finance, reserve stock or complete dispatch |
| Customer-visible order history and tracking | `oasis-baklawa` | Central and Trace provide governed projections | Customer-safe read models | Customer App must not infer status from raw operational tables |
| Client administration | `Oasis-Baklawa-Central` | Customer App reads safe account state | Canonical company/buyer records | Customer App must not perform staff-only client administration |
| Pricing governance, MOQ and commercial approval | `Oasis-Baklawa-Central` | Customer App reads eligible price projection | Canonical pricing and approval records | AI Studio must not set transaction prices |
| Order acceptance and operational orchestration | `Oasis-Baklawa-Central` | Customer App reads status; Trace receives approved references | Canonical order and workflow records | Trace must not accept or commercially approve orders |
| Finance release and credit controls | `Oasis-Baklawa-Central` | Customer App receives safe status only | Canonical finance release records | Customer App and Trace must not mutate finance authority |
| Production planning and execution coordination | `Oasis-Baklawa-Central` | Trace receives approved execution references | Canonical production requirement/work records | Customer App must not trigger production directly |
| Inventory coordination and reservations | `Oasis-Baklawa-Central` | Customer App reads availability summary; Trace records physical identity/movement | Canonical reservation and inventory control records | Customer App must not mutate stock; Trace must not own commercial reservation logic |
| Exceptions, escalations, WhatsApp accountability and command dashboards | `Oasis-Baklawa-Central` | Other apps may surface bounded links/status | Canonical accountability and operational event records | No other app may create a parallel escalation truth |
| Product master authoring | `oasis-ai-studio` | Central, Customer App and Trace consume approved product identity | Canonical product master | Central and Customer App must not create competing product-master edits |
| Product media, copy, aliases and enrichment | `oasis-ai-studio` | Customer App and Central consume published content | Canonical product/media records | Trace must not own editorial content |
| Catalogue composition, label content and publication readiness | `oasis-ai-studio` | Customer App consumes published catalogue projection | Canonical catalogue/label content records | Customer App must not publish unapproved content |
| Physical unit and lot identity | `oasis-trace` | Central consumes movement/evidence; Customer App reads safe status | Canonical traceability records | Central must not create a competing scan ledger |
| Cartonisation and dispatch-bundle membership | `oasis-trace` | Central coordinates readiness | Canonical carton and bundle records | Customer App must not mutate carton membership |
| Barcode/QR labels, printers, print logs and reprints | `oasis-trace` | Central audits | Canonical print/reprint evidence | AI Studio may prepare label content but must not own physical print execution truth |
| Gate scans and physical chain of custody | `oasis-trace` | Central and Customer App consume governed status | Immutable scan/event history | Central must not rewrite physical scan history |
| Authentication platform | `oasis-supabase-core` | All applications | Supabase Auth plus canonical profile/membership records | No application may create a separate password authority |
| Database schema, RLS, grants, triggers, RPCs, Edge Functions and generated types | `oasis-supabase-core` | All applications | Canonical Supabase project | No application repository may independently evolve production schema |

## Transitional exceptions

Current storefront routes inside Central remain operational until the dedicated Customer App reaches parity. Their existence does not grant permanent ownership.

Existing migrations or backend assumptions in application repositories must be inventoried and either archived, moved forward into Supabase Core through new canonical migrations, or formally retired. Committed migrations are never amended.

## Change gate

Any future feature proposal must name:

- primary repository owner;
- canonical entity or entities touched;
- reads required;
- writes required;
- command or event contract;
- RLS/permission impact;
- rollback path;
- proof that no second source of truth is introduced.
