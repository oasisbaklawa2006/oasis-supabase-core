# Oasis Enterprise Feature Registry

Generated: 2026-07-07
Scope: Oasis AI Studio, Oasis Central, Oasis Supabase Core, Oasis Trace / Labelling
Purpose: Canonical feature-level inventory for the next development engine.

This file complements SCREEN_REGISTRY.md. SCREEN_REGISTRY.md tracks screens/routes; this file tracks functional capabilities.

## Status Legend

| Status | Meaning |
|---|---|
| BUILT_VALIDATED | Built and validated with direct evidence |
| BUILT_NEEDS_EVIDENCE | Built or believed built, but needs fresh evidence |
| PARTIAL | Partly built; usable in limited scope or missing a key path |
| NOT_BUILT | Planned but not implemented |
| BLOCKED | Cannot proceed until dependency/decision is resolved |
| PLANNED | Intended part of the app but no build evidence yet |
| UNKNOWN_VALIDATE | Mentioned or implied, but implementation status must be checked |

## Completion Rule

A feature is not complete just because a screen exists. Mark BUILT_VALIDATED only when UI, backend, auth/RLS, workflow, audit/error path, and evidence are known.

---

# 1. WhatsApp / Operator Inbox / Studio Bridge

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Legacy WhatsApp webhook receiver | Oasis Central / Supabase Core | BUILT_VALIDATED | whatsapp-webhook receives fresh inbound messages into public.whatsapp_messages | Do not redeploy from AI Studio |
| ERP WhatsApp message persistence | Supabase Core | BUILT_VALIDATED | Fresh rows confirmed in public.whatsapp_messages | Monitor only |
| Studio inbox bridge edge function | Oasis AI Studio | BUILT_VALIDATED | whatsapp-studio-inbox-bridge deployed and dry-run works | Keep manual unless cron approved |
| Bridge secret auth | Oasis AI Studio / Supabase | BUILT_VALIDATED | Local secret file works | Rotate at final go-live |
| Bridge dry-run mode | Oasis AI Studio | BUILT_VALIDATED | dry_run=true reads post-cursor rows | Preserve |
| Bridge live ingest mode | Oasis AI Studio | BUILT_VALIDATED | Controlled run tested | Keep disabled by default |
| Bridge duplicate protection | Oasis AI Studio | BUILT_VALIDATED | Duplicate rows counted without failure | Preserve |
| Bridge cursor state | Supabase Core | BUILT_VALIDATED | whatsapp_studio_inbox_bridge_state advances | Document before any backfill |
| Bridge scheduled polling / cron | Oasis AI Studio / Supabase | NOT_BUILT | Intentionally off | Decide only after handover |
| Historical WhatsApp backfill | Oasis AI Studio / Supabase | NOT_BUILT | Cursor intentionally jumped near current time | Requires written strategy |
| Studio inbound table | Supabase Core | BUILT_VALIDATED | public.whatsapp_inbound_messages populated | Preserve RLS |
| Resolver execution on inbound | Oasis AI Studio | BUILT_VALIDATED | resolver_status=resolved, resolver_result_json populated | Continue tuning |
| Resolver product clarification | Oasis AI Studio | BUILT_VALIDATED | ask_clarification for ambiguous messages | Improve UX later |
| Resolver direct auto-suggest | Oasis AI Studio | BUILT_NEEDS_EVIDENCE | Evidence exists for high-confidence messages | Add regression tests |
| Resolver failure handling | Oasis AI Studio | PARTIAL | Failed legacy rows exist | Improve error display |
| Operator Inbox list | Oasis AI Studio | BUILT_VALIDATED | UI displayed live rows after RLS fix | Keep |
| Operator Inbox RLS access | Supabase Core | BUILT_VALIDATED | purecocoa@live.in mapped to super_admin | Add remaining users if required |
| Operator select alternative | Oasis AI Studio | BUILT_VALIDATED | Cashew Pyramid alternative selected | Preserve audit |
| Operator confirm decision | Oasis AI Studio | BUILT_VALIDATED | action=confirm audit row exists | Preserve |
| Operator reject decision | Oasis AI Studio | BUILT_VALIDATED | Reject row exists for test message | Preserve |
| WhatsApp draft creation | Oasis AI Studio / Supabase | BUILT_VALIDATED | Draft created from inbound message | Preserve |
| Operator decision audit | Supabase Core | BUILT_VALIDATED | whatsapp_operator_decisions row linked to draft | Append-only principle |
| WhatsApp draft review status | Oasis AI Studio | BUILT_VALIDATED | UNDER_REVIEW row confirmed | Continue |
| WhatsApp draft to live Sales Order | Oasis Central | NOT_BUILT | Explicitly not built | Future Golden Pipeline work |
| WhatsApp reply automation | Oasis AI Studio / Central | NOT_BUILT | No auto-reply path confirmed | Future only |
| WhatsApp media ingestion | Oasis AI Studio / Central | PARTIAL | ERP can store image/video rows; resolver path text-focused | Define media policy |
| WhatsApp contact enrichment | Oasis AI Studio / Central | PARTIAL | Customer name seen for known sender | Validate contact sync |

# 2. Product Catalogue / AI Studio

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Product master table integration | Oasis AI Studio / Supabase | BUILT_NEEDS_EVIDENCE | Resolver reads products | Validate full schema |
| Product aliases | Oasis AI Studio / Supabase | BUILT_VALIDATED | Alias loader patched to live schema | Add regression test |
| Product alias approval workflow | Oasis AI Studio | PARTIAL | Prior PR/migration work referenced | Validate UI path |
| SKU-based resolution | Oasis AI Studio | BUILT_VALIDATED | Cashew Pyramid SKU resolved | Continue |
| Product alternatives ranking | Oasis AI Studio | BUILT_VALIDATED | Alternatives shown for pyramid | Continue tuning |
| Catalogue loader | Oasis AI Studio | BUILT_VALIDATED | Fixed for alias_text, canonical_name | Preserve live-compatible fields |
| Product media bucket | Supabase Core | BUILT_NEEDS_EVIDENCE | Earlier drift fixed / migration referenced | Verify policies |
| AI-generated product media | Oasis AI Studio | PARTIAL | Planned and referenced | Validate current UI |
| Product packaging assets | Oasis AI Studio | PARTIAL | Mentioned in app plan | Validate |
| Product truth snapshots | Oasis AI Studio / Supabase | PARTIAL | Mentioned in drift/workflow | Validate schema |
| Product catalogue versioning | Oasis AI Studio | PARTIAL | catalogue_versions drift previously seen | Verify live state |
| Product sync events | Oasis AI Studio | PARTIAL | Previously missing in drift | Verify live state |
| Product BOM required flag | Oasis Central / AI Studio | BUILT_NEEDS_EVIDENCE | Earlier live mismatch fixed | Verify in live DB |
| Product piece weight / pieces per kg | Oasis AI Studio | BUILT_NEEDS_EVIDENCE | Used in quantity resolution plans | Validate data completeness |
| Product category/tag system | Oasis AI Studio | PARTIAL | Tag/alias approval work referenced | Validate |
| Product family / variant modeling | Oasis AI Studio | PARTIAL | Resolver distinguishes product families | Improve catalogue governance |
| Product image hero generation workflow | Oasis AI Studio | PLANNED | Business requirement exists | Build later |
| Product nutrition / FSSAI label data | Oasis AI Studio / Trace | PLANNED | Business requirement exists | Build later |
| HSN / GST product mapping | Oasis Central / AI Studio | PLANNED | Business requirement exists | Build later |

# 3. Sales Order / Golden Pipeline / ERP Core

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Sales order draft table set | Oasis Central / Supabase | BUILT_VALIDATED | Sprint 9 tables referenced | Validate latest production |
| Draft workflow statuses | Oasis Central | BUILT_VALIDATED | AI_DRAFT, UNDER_REVIEW, APPROVED_FOR_SO, REJECTED | Preserve gates |
| Readiness gates | Oasis Central | BUILT_VALIDATED | client/product/quantity/address/payment terms | Continue |
| Approval blocked until readiness passes | Oasis Central | BUILT_VALIDATED | Sprint 9 invariant | Preserve |
| Approved draft does not create live SO | Oasis Central | BUILT_VALIDATED | Explicit design | Do not bypass |
| Sales order draft audit log | Oasis Central | BUILT_VALIDATED | Append-only principle | Preserve |
| Live Sales Order creation from approved draft | Oasis Central | NOT_BUILT | Explicitly not implemented | Future controlled promotion |
| Golden Pipeline SO creation | Oasis Central | PARTIAL | Older ERP functionality exists; new promotion not built | Validate before extension |
| PI / Proforma Invoice | Oasis Central | BUILT_NEEDS_EVIDENCE | Existing domain | Validate |
| Dispatch readiness | Oasis Central | BUILT_NEEDS_EVIDENCE | Governance modules referenced | Validate |
| Dispatch completion | Oasis Central | BUILT_NEEDS_EVIDENCE | Governance modules referenced | Validate |
| Dispatch finalization | Oasis Central | BUILT_NEEDS_EVIDENCE | Governance modules referenced | Validate |
| Stock finalization | Oasis Central | BUILT_NEEDS_EVIDENCE | Governance modules referenced | Validate |
| Finance approval gates | Oasis Central | BUILT_NEEDS_EVIDENCE | Governance modules referenced | Validate |
| Invoice generation | Oasis Central | UNKNOWN_VALIDATE | ERP likely has invoice features | Verify |
| Payment allocation | Oasis Central | UNKNOWN_VALIDATE | Planned/ERP domain | Verify |
| Credit control | Oasis Central | PLANNED | Business-critical future area | Define |
| Order amendment governance | Oasis Central | PLANNED | Required for real operations | Build later |
| Order cancellation governance | Oasis Central | PLANNED | Required for real operations | Build later |

# 4. Warehouse / Dispatch / Gatekeeper

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Warehouse stock ledger | Oasis Central | UNKNOWN_VALIDATE | Operational domain | Verify |
| Pick list generation | Oasis Central | PLANNED | Needed for SO fulfillment | Build/validate |
| Packing confirmation | Oasis Central | PLANNED | Needed for dispatch | Build/validate |
| Dispatch checklist | Oasis Central | PLANNED | Needed for operations | Build |
| Gatekeeper dispatch control | Oasis Central / Trace | PLANNED | Mentioned in app vision | Build |
| Vehicle/loading confirmation | Oasis Central | PLANNED | Needed for dispatch | Build |
| Damage reporting | Oasis Central | PLANNED | Business requirement | Build |
| Returns handling | Oasis Central | PLANNED | Business requirement | Build |
| FIFO stock enforcement | Oasis Central | PLANNED | Important for food inventory | Build |
| Expiry/near-expiry liquidation workflow | Oasis Central | PLANNED | Distribution agreement requirement | Build later |
| Cold chain tracking | Oasis Trace | PLANNED | Frozen product requirement | Build later |

# 5. Finance / Accounts / GST / Compliance

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Finance governance module | Oasis Central | BUILT_NEEDS_EVIDENCE | Referenced governance code | Validate |
| Payment terms readiness gate | Oasis Central | BUILT_VALIDATED | Sprint 9 readiness gate | Preserve |
| GST / HSN product classification | Oasis Central / AI Studio | PLANNED | Business requirement | Build with legal review |
| GST dispute evidence repository | Oasis Central | PLANNED | Business need exists | Build later |
| Tally sales data cleanup workflow | Oasis Central | PLANNED | Manual work done earlier | Automate later |
| B2B customer ledger import | Oasis Central | PLANNED | Needed for analytics | Build later |
| Credit note / debit note workflows | Oasis Central | PLANNED | Needed for finance | Build later |
| Accounts receivable dashboard | Oasis Central | PLANNED | Needed for management | Build later |
| Margin reporting | Oasis Central | PLANNED | Needed for B2B | Build later |
| Channel-wise sales reporting | Oasis Central | PLANNED | Needed for management | Build later |

# 6. Labelling / Traceability / Oasis Trace

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Label app repo exists | Oasis Trace | BUILT_VALIDATED | Repo exists and handover pack pushed | Continue |
| Barcode label generation | Oasis Trace | PLANNED | App intent exists | Build |
| Sticker template management | Oasis Trace | PLANNED | App intent exists | Build |
| Batch/lot tracking | Oasis Trace | PLANNED | Food traceability requirement | Build |
| Product-to-label mapping | Oasis Trace / AI Studio | PLANNED | Required | Build |
| Label print audit | Oasis Trace | PLANNED | Required for control | Build |
| Packaging-level tracking | Oasis Trace | PLANNED | Required for retail/export | Build |
| QR traceability | Oasis Trace | PLANNED | Future capability | Build later |
| Expiry label governance | Oasis Trace | PLANNED | Food compliance | Build |
| Export label variants | Oasis Trace | PLANNED | Export packaging requirement | Build later |

# 7. Admin / Access / Security / Audit

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Team role map | Supabase Core | BUILT_VALIDATED | user_role_map confirmed | Preserve |
| is_team_member access function | Supabase Core | BUILT_VALIDATED | Used by Operator Inbox RLS | Preserve |
| Role-based access for Operator Inbox | Supabase Core / AI Studio | BUILT_VALIDATED | purecocoa@live.in fixed | Add remaining users if needed |
| Super admin access | Supabase Core | BUILT_VALIDATED | purecocoa@live.in true | Preserve |
| Other user access | Supabase Core | PARTIAL | dinesh_mutreja@yahoo.co.in false | Decide |
| RLS policies for inbound messages | Supabase Core | BUILT_VALIDATED | RLS issue diagnosed | Preserve |
| Secret inventory without values | All repos | BUILT_VALIDATED | Template exists | Maintain |
| Secret rotation | All repos / Supabase | NOT_BUILT | Pending final go-live | Rotate later |
| Audit log governance | Oasis Central / AI Studio | PARTIAL | Some audit tables exist | Expand |
| Admin UI phase gate | Oasis Central | PARTIAL | Phase 1 closeout warning exists | Validate before Phase 2 |
| Error monitoring | Oasis Central / AI Studio | PARTIAL | Manual diagnosis used | Build dashboard later |
| Edge function deployment runbooks | All repos | BUILT_VALIDATED | Runbooks exist | Maintain |

# 8. Reporting / Dashboards / Management

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Operator Inbox insight panels | Oasis Central / AI Studio | BUILT_NEEDS_EVIDENCE | Earlier PR referenced | Validate |
| Message volume reporting | Oasis Central | BUILT_NEEDS_EVIDENCE | Earlier PR referenced | Validate |
| Unanswered WhatsApp reporting | Oasis Central | BUILT_NEEDS_EVIDENCE | Earlier PR referenced | Validate |
| Customer summary cards | Oasis Central | BUILT_NEEDS_EVIDENCE | Earlier PR referenced | Validate |
| CMD / owner dashboard | Oasis Central | PLANNED | Needed for leadership | Build |
| Sales analytics | Oasis Central | PLANNED | Needed | Build |
| Product performance analytics | Oasis AI Studio / Central | PLANNED | Needed | Build |
| Dispatch performance analytics | Oasis Central | PLANNED | Needed | Build |
| Finance analytics | Oasis Central | PLANNED | Needed | Build |
| AI resolution quality dashboard | Oasis AI Studio | PLANNED | Needed for resolver tuning | Build |
| Audit / compliance dashboard | Oasis Central | PLANNED | Needed | Build |

# 9. Integrations

| Feature | Owner Repo | Status | Evidence / Notes | Next Action |
|---|---|---|---|---|
| Supabase production project | Supabase Core | BUILT_VALIDATED | tcxvcatsqqertcnycuop used | Preserve |
| Supabase Edge Functions | Supabase Core / AI Studio | BUILT_VALIDATED | Bridge deployed | Continue |
| WhatsApp provider / Meta webhook | Oasis Central | BUILT_VALIDATED | Restored and receiving | Monitor |
| MSG91 credentials / provider configs | Oasis Central | UNKNOWN_VALIDATE | Secret names tracked only | Verify |
| Tally integration | Oasis Central | PLANNED | Business need | Build later |
| Shopify/e-commerce integration | Oasis Central / AI Studio | PLANNED | Not confirmed | Future |
| POS integration | Oasis Central | PLANNED | Retail need | Future |
| Barcode printer integration | Oasis Trace | PLANNED | Future |
| Google Drive / file storage | All repos | UNKNOWN_VALIDATE | Not core yet | Future |
| Vercel deployment | Oasis AI Studio / Central | BUILT_NEEDS_EVIDENCE | Live preview used earlier | Validate env vars |

# 10. Explicitly Not Built Yet

1. Scheduled WhatsApp bridge polling
2. Historical WhatsApp backfill
3. WhatsApp draft to live Sales Order promotion
4. Automatic invoice generation from WhatsApp draft
5. Automatic dispatch from WhatsApp draft
6. Full product media generation governance
7. Full label/barcode production system
8. Batch/lot traceability
9. GST/HSN compliance engine
10. Tally auto-sync
11. CMD dashboard
12. Full finance dashboard
13. Automated customer credit control
14. Full warehouse pick/pack/dispatch workflow
15. Secret rotation completion
16. Full 62-screen validation evidence

# 11. Maintenance Rule

Every future PR must update this file if it changes feature status, ownership, screen coverage, data flow, automation state, or phase readiness.
