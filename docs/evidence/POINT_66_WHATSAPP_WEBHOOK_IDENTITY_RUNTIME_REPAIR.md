# POINT66 — WhatsApp webhook identity runtime repair

**Core main SHA:** `5066064` (POINT36-CORE)

## Scope

Software residual repair for Point66 sender / original-customer identity. No migration, no protected corpus, no production mutation.

## Removed runtime bypasses (`whatsapp-webhook`)

| Legacy bypass | Repair |
|---|---|
| `ilike` phone/name/GST company auto-link | `whatsapp_resolve_governed_customer` RPC only |
| Shadow company creation (`status: shadow`) | Removed — unresolved stays fail-closed |
| Context-stitch order retarget | Removed |
| Staff relay sender→customer inference | Governed RPC employee-relay safety |

## New edge tests

`supabase/functions/_shared/wa-governance/resolveWebhookCompany.test.ts` (9 assertions):

- Unique explicit `company_id` binding
- Shared-phone ambiguity fail-closed
- Forwarded employee relay unresolved without candidate
- Fuzzy name/GST collision → `AMBIGUOUS` from governed RPC
- Cross-company retarget denial (structural)
- Unresolved fail-closed
- Staff relay exact candidate extraction
- Forwarded payload provenance extraction

## Gate state

| Gate | Status |
|---|---|
| Edge identity unit tests | **PASS** (9/9) |
| Webhook recertification guard | **PASS** |
| New migration | **NONE** |
| Live-provider identity evidence | **NOT CLEARED** |
| Programme Point66 cleared | **NO** — `PR MERGED != STAGE CLEARED` |

Reviewer requested: `dineshmutrejabackup-cmd`. **STOP before merge.**
