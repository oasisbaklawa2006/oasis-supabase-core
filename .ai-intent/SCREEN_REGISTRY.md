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

## Central Admin Route Reconciliation - 2026-07-07

Docs-only reconciliation pass. Parsed the live route tree in `src/App.tsx` (the `/admin` layout route and its children, lines ~302-513) against this registry. No source files were changed to produce this section.

**Summary**

- 75 real, component-backed `/admin/*` screens found (the `/admin` index route plus its 74 non-redirect child routes). 6 legacy `<Navigate>` redirect stubs (`customers`, `assembly`, `finance/payments`, `finance/invoices`, `crm`, `roles`) were excluded — they render no screen of their own.
- 6 of the 75 were already represented in this registry under an exact matching route: `/admin` (#2), `/admin/finance-board` (#3), `/admin/operator-inbox` (#6), `/admin/dispatch` (#8), `/admin/approvals` (#19), `/admin/logistics` (#22).
- 69 routes were missing from the registry and are added below with conservative statuses.
- 0 of the 69 newly added rows are marked `BUILT_VALIDATED`. Statuses used are `PARTIAL` (route is a documented alias re-using another route's component), `BUILT_NEEDS_EVIDENCE` (route + component wired, no captured data-path/RLS/smoke evidence), and `UNKNOWN_VALIDATE` (route is additionally gated behind `AdminModuleRoute`, i.e. feature-flagged/experimental rollout — status unverified).
- Backend Dependencies were not re-derived in this pass; each row is marked "Not enumerated" pending a dedicated data-path audit. RLS/Auth reflects only what is verifiable directly from `src/App.tsx` (the `RoleProtectedRoute allowedRoles={[...ADMIN_STAFF_ROLES]}` gate on the `/admin` layout route, plus any `AdminModuleRoute` module gate).

| # | App | Route | Screen | Module | Status | Component (source) | Backend Dependencies | RLS/Auth | Role | Phase |
|---:|---|---|---|---|---|---|---|---|---|---|
| 63 | Central | /admin/clients | Clients | CRM | BUILT_NEEDS_EVIDENCE | AdminClients | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 64 | Central | /admin/products | Products (Admin) | Product Ops | BUILT_NEEDS_EVIDENCE | AdminProducts | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 65 | Central | /admin/pricing | Pricing Matrix | Finance | BUILT_NEEDS_EVIDENCE | AdminPricing (ErrorBoundary-wrapped) | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 66 | Central | /admin/orders | Orders (Admin) | Golden Pipeline | BUILT_NEEDS_EVIDENCE | AdminOrders | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 67 | Central | /admin/production | Production | Production | BUILT_NEEDS_EVIDENCE | AdminProduction | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 68 | Central | /admin/operations | Operations | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminOperations | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 69 | Central | /admin/packing-dispatch | Packing & Dispatch | Dispatch | BUILT_NEEDS_EVIDENCE | AdminPackingDispatch | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 70 | Central | /admin/accounts-release | Accounts Release | Finance | BUILT_NEEDS_EVIDENCE | AdminAccountsRelease | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 71 | Central | /admin/exceptions | Exceptions | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminExceptions | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 72 | Central | /admin/finance | Finance | Finance | BUILT_NEEDS_EVIDENCE | AdminFinance | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 73 | Central | /admin/finance-governance | Finance Governance Board | Finance | BUILT_NEEDS_EVIDENCE | FinanceGovernanceBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 74 | Central | /admin/users | Users | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminUsers | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 75 | Central | /admin/moq | MOQ | Catalogue | BUILT_NEEDS_EVIDENCE | AdminMOQ | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 76 | Central | /admin/currency | Currency | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminCurrency | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 77 | Central | /admin/support | Support | Support | BUILT_NEEDS_EVIDENCE | AdminSupport | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 78 | Central | /admin/whatsapp | WhatsApp (route alias) | WhatsApp | PARTIAL | OperatorInbox (alias of /admin/operator-inbox) | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 79 | Central | /admin/settings | Settings | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminSettings | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 80 | Central | /admin/audit | Audit | Governance | BUILT_NEEDS_EVIDENCE | AdminAudit | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 81 | Central | /admin/department | Department | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminDepartment | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 82 | Central | /admin/inventory | Inventory | Inventory | BUILT_NEEDS_EVIDENCE | AdminInventory | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 83 | Central | /admin/sales-hub | Sales Performance Hub | Sales | BUILT_NEEDS_EVIDENCE | SalesPerformanceHub | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 84 | Central | /admin/notifications | Notifications | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminNotifications | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 85 | Central | /admin/heartbeat | Heartbeat (route alias) | Monitoring | PARTIAL | AdminDashboard (alias of /admin index) | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 86 | Central | /admin/display-management | Display Management | TV/Display | BUILT_NEEDS_EVIDENCE | DisplayManagement | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 87 | Central | /admin/merchandising | Merchandising | Catalogue | BUILT_NEEDS_EVIDENCE | AdminMerchandising | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 88 | Central | /admin/catalogue-sync | Catalogue Sync Status | Catalogue | BUILT_NEEDS_EVIDENCE | AdminCatalogueSyncStatus | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 89 | Central | /admin/catalogue-approvals | Catalogue Approval Inbox | Catalogue | BUILT_NEEDS_EVIDENCE | ApprovalInbox | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 90 | Central | /admin/order-management | Order Management | Golden Pipeline | BUILT_NEEDS_EVIDENCE | OrderManagement | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 91 | Central | /admin/central-pool | Central Order Pool | Golden Pipeline | BUILT_NEEDS_EVIDENCE | CentralOrderPool | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 92 | Central | /admin/cmd-war-room | CMD War Room | Monitoring | BUILT_NEEDS_EVIDENCE | CMDWarRoom | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 93 | Central | /admin/inventory-command-center | Inventory Command Center | Inventory | BUILT_NEEDS_EVIDENCE | InventoryCommandCenter | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 94 | Central | /admin/carton-explorer | Carton Explorer | Inventory | BUILT_NEEDS_EVIDENCE | CartonExplorer | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 95 | Central | /admin/reservation-board | Reservation Board | Inventory | BUILT_NEEDS_EVIDENCE | ReservationBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 96 | Central | /admin/inventory-risk-board | Inventory Risk Board | Inventory | BUILT_NEEDS_EVIDENCE | InventoryRiskBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 97 | Central | /admin/scan-timeline | Scan Timeline | Tracking | BUILT_NEEDS_EVIDENCE | ScanTimeline | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 98 | Central | /admin/assembly-tasks | Assembly Management | Production | BUILT_NEEDS_EVIDENCE | AssemblyManagement | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 99 | Central | /admin/assembly-tv | Assembly TV | TV/Display | BUILT_NEEDS_EVIDENCE | AssemblyTV | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 100 | Central | /admin/ready-goods | Ready Goods Store | Warehouse | BUILT_NEEDS_EVIDENCE | ReadyGoodsStore | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 101 | Central | /admin/store-coordination | Store Coordination | Warehouse | BUILT_NEEDS_EVIDENCE | StoreCoordination | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 102 | Central | /admin/label-command-center | Label Command Center | Labelling | BUILT_NEEDS_EVIDENCE | LabelCommandCenter | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 103 | Central | /admin/customer-timeline-preview | Customer Timeline Preview | Monitoring | UNKNOWN_VALIDATE | CustomerTimelinePreview | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 104 | Central | /admin/operational-search | Operational Global Search | Monitoring | UNKNOWN_VALIDATE | OperationalGlobalSearch | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 105 | Central | /admin/live-work-queues | Live Work Queues | Monitoring | UNKNOWN_VALIDATE | LiveWorkQueues | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 106 | Central | /admin/entity-graph-explorer | Entity Graph Explorer | Monitoring | UNKNOWN_VALIDATE | EntityGraphExplorer | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 107 | Central | /admin/queue-execution-preview | Queue Execution Preview | Monitoring | UNKNOWN_VALIDATE | QueueExecutionPreview | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 108 | Central | /admin/barcode-execution-preview | Barcode Execution Preview | Monitoring | UNKNOWN_VALIDATE | BarcodeExecutionPreview | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 109 | Central | /admin/product-intelligence-prototype | Product Intelligence Prototype | Monitoring | UNKNOWN_VALIDATE | ProductIntelligencePrototype | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 110 | Central | /admin/execution-command-center | Execution Command Center | Monitoring | UNKNOWN_VALIDATE | ExecutionCommandCenter | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 111 | Central | /admin/execution-risk | Execution Risk Board | Monitoring | UNKNOWN_VALIDATE | ExecutionRiskBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 112 | Central | /admin/execution-bottlenecks | Execution Bottlenecks | Monitoring | UNKNOWN_VALIDATE | ExecutionBottlenecks | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(cmd_war_room) | staff/admin | Reconciliation 2026-07-07 |
| 113 | Central | /admin/execution/production | Production Execution Board | Execution | UNKNOWN_VALIDATE | ProductionExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(production) | staff/admin | Reconciliation 2026-07-07 |
| 114 | Central | /admin/execution/assembly | Assembly Execution Board | Execution | UNKNOWN_VALIDATE | AssemblyExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(production) | staff/admin | Reconciliation 2026-07-07 |
| 115 | Central | /admin/execution/ready-goods | Ready Goods Execution Board | Execution | UNKNOWN_VALIDATE | ReadyGoodsExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(inventory) | staff/admin | Reconciliation 2026-07-07 |
| 116 | Central | /admin/execution/dispatch | Dispatch Execution Board | Execution | UNKNOWN_VALIDATE | DispatchExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(dispatch) | staff/admin | Reconciliation 2026-07-07 |
| 117 | Central | /admin/execution/third-party | Third Party Execution Board | Execution | UNKNOWN_VALIDATE | ThirdPartyExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(orders) | staff/admin | Reconciliation 2026-07-07 |
| 118 | Central | /admin/execution/retail | Retail Execution Board | Execution | UNKNOWN_VALIDATE | RetailExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(inventory) | staff/admin | Reconciliation 2026-07-07 |
| 119 | Central | /admin/execution/complaints | Complaints Execution Board | Execution | UNKNOWN_VALIDATE | ComplaintsExecutionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES + AdminModuleRoute(support) | staff/admin | Reconciliation 2026-07-07 |
| 120 | Central | /admin/rgs-tv | Ready Goods TV | TV/Display | BUILT_NEEDS_EVIDENCE | ReadyGoodsTV | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 121 | Central | /admin/golden-chain-operator | Golden Chain Operator Wizard | Golden Pipeline | BUILT_NEEDS_EVIDENCE | GoldenChainOperatorWizard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 122 | Central | /admin/dispatch-readiness | Dispatch Readiness Board | Dispatch | BUILT_NEEDS_EVIDENCE | DispatchReadinessBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 123 | Central | /admin/dispatch-completion | Dispatch Completion Board | Dispatch | BUILT_NEEDS_EVIDENCE | DispatchCompletionBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 124 | Central | /admin/dispatch-finalization | Dispatch Finalization Board | Dispatch | BUILT_NEEDS_EVIDENCE | DispatchFinalizationBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 125 | Central | /admin/stock-finalization | Stock Finalization Board | Inventory | BUILT_NEEDS_EVIDENCE | StockFinalizationBoard | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 126 | Central | /admin/dispatch-mgmt | Dispatch Management | Dispatch | BUILT_NEEDS_EVIDENCE | DispatchManagement | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 127 | Central | /admin/dispatch-tv | Dispatch TV | TV/Display | BUILT_NEEDS_EVIDENCE | DispatchTV | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 128 | Central | /admin/target-vs-actual | Target vs Actual | Monitoring | BUILT_NEEDS_EVIDENCE | TargetVsActual | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 129 | Central | /admin/3pcs-store | Third Party Goods Store | Warehouse | BUILT_NEEDS_EVIDENCE | ThirdPartyStore | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 130 | Central | /admin/verification | Verification War Room | Monitoring | BUILT_NEEDS_EVIDENCE | VerificationWarRoom | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |
| 131 | Central | /admin/announcements | Announcements | Admin Ops | BUILT_NEEDS_EVIDENCE | AdminAnnouncements | Not enumerated | RoleProtectedRoute: ADMIN_STAFF_ROLES | staff/admin | Reconciliation 2026-07-07 |

### Reverse-drift notes

Registry rows (from the original 62-screen table, #7-25) whose recorded `/admin/*` route does not exist as a real route in `src/App.tsx` today, or appears to have been renamed:

**Likely renamed (a differently-named real route serves the same apparent purpose):**
- #23 `/admin/customers` (Customers) — this path is now only a `<Navigate>` redirect to `/admin/clients`. The real screen (`AdminClients`) lives at `/admin/clients` (added above as #63).
- #25 `/admin/audit-log` (Audit Log) — no route at this exact path; `/admin/audit` (`AdminAudit`) exists instead (added above as #80).
- #21 `/admin/cmd-dashboard` (CMD TV Dashboard) — no route at this exact path; `/admin/cmd-war-room` (`CMDWarRoom`) exists instead (added above as #92).
- #12 `/admin/warehouse/ready-goods` (Ready Goods Store) — no route at this exact path; `/admin/ready-goods` (`ReadyGoodsStore`) exists instead, flattened out of the `/warehouse` prefix (added above as #100).
- #13 `/admin/warehouse/third-party` (Third Party Goods Store) — no route at this exact path; `/admin/3pcs-store` (`ThirdPartyStore`) exists instead (added above as #129).

**No corresponding real route found (possible phantom entries or since-removed screens — not addable as a confirmed rename without further evidence):**
- #7 `/admin/sales-order-drafts` (Sales Order Draft Review)
- #9 `/admin/gatekeeper` (Gatekeeper Exit Control)
- #10 `/admin/warehouse` (Warehouse Overview) — no direct successor identified; possibly superseded by `/admin/inventory` or `/admin/inventory-command-center`.
- #11 `/admin/warehouse/packing-assembly` (Packing & Assembly) — no direct successor identified; possibly superseded by `/admin/packing-dispatch` or `/admin/assembly-tasks`.
- #14 `/admin/proforma-invoices` (Proforma Invoices)
- #15 `/admin/billing` (Billing Engine)
- #16 `/admin/e-way-bills` (E-Way Bills)
- #17 `/admin/payments` (Payment Verification) — possibly folded into `/admin/finance` or `/admin/accounts-release`.
- #18 `/admin/payment-variances` (Payment Variance Approval)
- #20 `/admin/tickets` (Internal Tickets) — possibly folded into `/admin/support`.
- #24 `/admin/reports` (Reports)

These reverse-drift rows are noted only; the original table (#1-62) was left untouched per the docs-only, append-only scope of this reconciliation.
