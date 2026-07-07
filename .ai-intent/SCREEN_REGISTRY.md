# SCREEN_REGISTRY.md

## Purpose

Canonical inventory for the planned 62-screen ecosystem. Status values must be updated only after route, data path, RLS, and smoke evidence are captured.

| # | App | Route | Screen | Module | Status | Backend Dependencies | RLS/Auth | Role | Phase |
|---:|---|---|---|---|---|---|---|---|---|
| 1 | Architecture | /.ai-intent | Handover Index | Architecture | built | Docs | N/A | N/A | Phase 0 |
| 2 | Central | /admin | Admin Shell | Admin UI | partly built | profiles,user_role_map,roles | is_team_member | admin/super_admin | Phase 1 |
| 3 | Central | /admin/finance-board | Finance Board | Finance | partly built | orders,payments,finance tables | team roles | finance/admin | Phase 1 |
| 4 | Central | /orders | Orders | Golden Pipeline | partly built | orders/order lines | team roles | sales/ops | Phase 2 |
| 5 | Central | /catalogue | Catalogue Consumer View | Catalogue | partly built | products,product_aliases | team roles | catalogue/sales | Phase 1 |
| 6 | Central/AI Studio | /admin/operator-inbox | WhatsApp Operator Inbox | WhatsApp | built/validated | whatsapp_inbound_messages,whatsapp_sales_order_drafts,whatsapp_operator_decisions | is_team_member | sales/ops/admin | Phase 2F/2G |
| 7 | Central | /admin/sales-order-drafts | Sales Order Draft Review | Order Drafts | partly built | whatsapp_sales_order_drafts,sales_order_drafts | team roles | sales/admin | Phase 2 |
| 8 | Central | /admin/dispatch | Dispatch Board | Dispatch | partly built | dispatch tables | team roles | dispatch/admin | Phase 2 |
| 9 | Central | /admin/gatekeeper | Gatekeeper Exit Control | Gatekeeper | not built | dispatch,labels,invoices,payments | team roles | gatekeeper/admin | Phase 2 |
| 10 | Central | /admin/warehouse | Warehouse Overview | Warehouse | not built | warehouse tables | team roles | warehouse/admin | Phase 2 |
| 11 | Central | /admin/warehouse/packing-assembly | Packing & Assembly | Warehouse | not built | stock_movements,batches | team roles | packing/admin | Phase 2 |
| 12 | Central | /admin/warehouse/ready-goods | Ready Goods Store | Warehouse | not built | stock,batches,allocations | team roles | warehouse/admin | Phase 2 |
| 13 | Central | /admin/warehouse/third-party | Third Party Goods Store | Warehouse | not built | third_party_stock,vendors | team roles | warehouse/admin | Phase 2 |
| 14 | Central | /admin/proforma-invoices | Proforma Invoices | Finance Docs | not built | proforma_invoices | team roles | finance/sales | Phase 2 |
| 15 | Central | /admin/billing | Billing Engine | Finance Docs | not built | invoices,taxes | team roles | finance/admin | Phase 2 |
| 16 | Central | /admin/e-way-bills | E-Way Bills | Compliance Docs | not built | eway_bills,invoices,dispatch | team roles | finance/dispatch | Phase 2 |
| 17 | Central | /admin/payments | Payment Verification | Finance | partly built | payments,orders | team roles | finance/admin | Phase 2 |
| 18 | Central | /admin/payment-variances | Payment Variance Approval | Approvals | not built | approvals,payments | team roles | finance_head/admin | Phase 2 |
| 19 | Central | /admin/approvals | Approval Center | Approvals | partly built | approval tables | team roles | manager/admin | Phase 2 |
| 20 | Central | /admin/tickets | Internal Tickets | Admin Ops | not built | tickets,ticket_events | team roles | staff/admin | Phase 2 |
| 21 | Central | /admin/cmd-dashboard | CMD TV Dashboard | Monitoring | not built | orders,dispatch,payments | read-only role | owner/admin | Phase 2 |
| 22 | Central | /admin/logistics | Logistics Tracking | Logistics | not built | dispatch,transporter | team roles | dispatch/admin | Phase 2 |
| 23 | Central | /admin/customers | Customers | CRM | partly built | customers/profiles | team roles | sales/admin | Phase 2 |
| 24 | Central | /admin/reports | Reports | Monitoring | not built | aggregates | team roles | admin/owner | Phase 2 |
| 25 | Central | /admin/audit-log | Audit Log | Governance | partly built | audit tables | team roles | admin/owner | Phase 2 |
| 26 | AI Studio | /products | Product List | Product Master | built/partly verified | products | team roles | catalogue/admin | Phase 2A |
| 27 | AI Studio | /products/new/fast | Fast Create Product | Product Master | partly built | products,media | team roles | catalogue/admin | Phase 2A |
| 28 | AI Studio | /products/:id | Product Detail | Product Master | partly built | products,product_media | team roles | catalogue/admin | Phase 2A |
| 29 | AI Studio | /products/:id/media | Product Media | Media | partly built | product_media,storage | team roles | catalogue/admin | Phase 2A |
| 30 | AI Studio | /products/:id/aliases | Product Aliases | Resolver | partly built | product_aliases | team roles | catalogue/admin | Phase 2A |
| 31 | AI Studio | /resolver-preview | Resolver Preview | Resolver | built/validated | products,product_aliases | team roles | catalogue/admin | Phase 2A |
| 32 | AI Studio | /catalogue/collections | Catalogue Collections | Catalogue | partly built | catalogue_collections | team roles | catalogue/admin | Phase 2 |
| 33 | AI Studio | /catalogue/publish | Publish Catalogue | Catalogue | partly built | catalogue tables | team roles | catalogue/admin | Phase 2 |
| 34 | AI Studio | /catalogue/pdf | PDF Generator | Distribution | not built | catalogue,pdf_jobs | team roles | catalogue/admin | Phase 2 |
| 35 | AI Studio | /catalogue/whatsapp | WhatsApp Catalogue Export | Distribution | not built | catalogue,pdf_jobs | team roles | sales/catalogue | Phase 2 |
| 36 | AI Studio | /compliance/fssai | FSSAI Dataset | Compliance | not built | fssai/product_compliance | team roles | catalogue/admin | Phase 2 |
| 37 | AI Studio | /compliance/nutrition | Nutrition Dataset | Compliance | not built | nutrition facts | team roles | catalogue/admin | Phase 2 |
| 38 | AI Studio | /compliance/legal-metrology | Legal Metrology | Compliance | not built | legal_metrology | team roles | catalogue/admin | Phase 2 |
| 39 | AI Studio | /export-config | Export Config | Export | not built | export configs | team roles | export/catalogue | Phase 2 |
| 40 | AI Studio | /media/hero-generator | Hero Image Generator | Media AI | partly built/workflow defined | product_media,storage | team roles | catalogue/admin | Phase 2 |
| 41 | AI Studio | /media/review | Media Review | Media Governance | not built | media_approvals | team roles | catalogue/admin | Phase 2 |
| 42 | AI Studio | /runtime/catalog-export | Runtime Catalogue Export | Resolver | partly built | runtime snapshots | team roles | system/admin | Phase 2 |
| 43 | AI Studio | /catalogue/retail | Retail Catalogue Variant | Distribution | not built | catalogue,pdf_jobs | team roles | catalogue/sales | Phase 2 |
| 44 | AI Studio | /catalogue/wholesale | Wholesale Catalogue Variant | Distribution | not built | catalogue,pdf_jobs | team roles | catalogue/sales | Phase 2 |
| 45 | AI Studio | /catalogue/export | Export Catalogue Variant | Distribution | not built | catalogue,pdf_jobs | team roles | export/catalogue | Phase 2 |
| 46 | Labelling | /labels | Label Dashboard | Labelling | partly built | label_queue | team roles | labels/admin | Phase 2 |
| 47 | Labelling | /labels/templates | Label Templates | Templates | not built | label_templates | team roles | labels/admin | Phase 2 |
| 48 | Labelling | /labels/print-queue | Print Queue | Printer | partly built | label_queue | team roles | labels/warehouse | Phase 2 |
| 49 | Labelling | /labels/barcodes | Barcode Generator | Barcode | not built | barcodes | team roles | labels/admin | Phase 2 |
| 50 | Labelling | /labels/qr | QR Generator | QR | not built | qr_codes | team roles | labels/admin | Phase 2 |
| 51 | Labelling | /labels/batch | Batch Labels | Tracking | not built | batches,label_queue | team roles | production/labels | Phase 2 |
| 52 | Labelling | /labels/processing | Processing Stage Labels | Tracking | not built | production stages | team roles | production/labels | Phase 2 |
| 53 | Labelling | /labels/assembly | Assembly Stage Labels | Tracking | not built | assembly tasks | team roles | packing/labels | Phase 2 |
| 54 | Labelling | /labels/packaging | Packaging Labels | Tracking | not built | packaging tasks | team roles | packing/labels | Phase 2 |
| 55 | Labelling | /labels/ready-goods | Ready Goods Labels | Tracking | not built | ready stock | team roles | warehouse/labels | Phase 2 |
| 56 | Labelling | /labels/third-party | Third Party Goods Labels | Tracking | not built | third_party_stock | team roles | warehouse/labels | Phase 2 |
| 57 | Labelling | /labels/order-allocation | Order Allocation Labels | Tracking | not built | allocations,orders | team roles | warehouse/dispatch | Phase 2 |
| 58 | Labelling | /labels/dispatch | Dispatch Carton Labels | Dispatch | not built | dispatch,orders | team roles | dispatch/labels | Phase 2 |
| 59 | Labelling | /labels/gatekeeper-scan | Gatekeeper Scan | Gatekeeper | not built | dispatch labels,gatekeeper | team roles | gatekeeper | Phase 2 |
| 60 | Labelling | /labels/reprint | Reprint Governance | Governance | not built | label_reprints | team roles | manager/admin | Phase 2 |
| 61 | Labelling | /labels/printers | Printer Setup | Hardware | not built | printer_config | team roles | labels/admin | Phase 2 |
| 62 | Labelling | /labels/audit | Label Audit | Audit | not built | label_audit | team roles | admin/owner | Phase 2 |

## Maintenance Rule

No new screen should be added without updating this registry. No screen should be marked built unless route, data read/write path, RLS, and UI smoke status are known.
