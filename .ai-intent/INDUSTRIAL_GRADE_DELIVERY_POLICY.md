# Industrial-Grade Delivery Policy

Generated: 2026-07-07
Purpose: Mandatory policy for building the Oasis Baklawa enterprise app ecosystem economically, quickly, correctly, and to industrial-grade quality.

This policy defines what “best possible app” means for Oasis: not just many screens, but a reliable, profitable, manageable, future-proof operating system for the business.

---

# 1. Prime Objective

Build the smallest correct next increment that improves real business operations without breaking proven flows.

Every development action must optimize for all six outcomes:

1. Lowest safe cost of development and Cursor/AI credits
2. Fastest safe delivery
3. Correct, error-free behavior
4. Industrial-grade reliability and auditability
5. Business generation and operational manageability
6. Future-proof extensibility without overengineering

Speed without correctness is not progress. Features without business value are not progress. Automation without governance is not progress.

---

# 2. Evidence-First Engineering

Before editing code, the AI engine must gather enough evidence to identify the responsible layer:

- UI/component
- route
- hook/service
- RPC/edge function
- table/view
- RLS/auth
- environment/secret
- external provider

The engine must not guess across layers. It must move from cheapest evidence to costlier work:

1. Inspect existing docs and registries
2. Search exact file/function names
3. Read targeted files
4. Run narrow SQL/read-only checks
5. Run narrow tests
6. Make minimal patch
7. Run targeted validation
8. Run full validation only when the risk justifies it

---

# 3. Vertical-Slice Rule

Build in end-to-end vertical slices, not isolated UI or isolated backend fragments.

A useful slice should usually include:

- screen/route behavior
- database/RPC/edge function behavior
- RLS/auth behavior
- audit trail if business-critical
- error handling
- validation proof
- registry update

Do not create screens that do not write/read real data unless they are explicitly marked prototype-only.

---

# 4. Golden Flow Protection

The following flows are protected and must not be degraded:

1. WhatsApp inbound to ERP persistence
2. Studio bridge ingestion/deduplication/cursor
3. Resolver execution and operator clarification
4. WhatsApp draft creation and audit trail
5. Sales order readiness gates
6. Finance, dispatch, stock, and audit governance
7. RLS/team access control
8. Product SKU/catalogue integrity

Any change touching a protected flow requires a targeted validation checklist before and after the change.

---

# 5. Future-Proof Architecture Rules

Future-proof means controlled evolution, not unnecessary complexity.

The engine must prefer:

- clear ownership boundaries
- stable contracts between repos
- schema migrations with compatibility
- typed interfaces where possible
- small modules with explicit responsibilities
- append-only audit where business decisions are recorded
- idempotent jobs and edge functions
- safe retries and duplicate protection
- feature flags for risky automation
- explicit phase gates

The engine must avoid:

- mega-components
- hidden business rules inside UI-only code
- duplicate sources of truth
- hardcoded product/customer/role logic
- untracked cron jobs
- silent schema drift
- broad service-role bypasses
- auto-generated code that no one can maintain

---

# 6. Industrial-Grade Reliability Requirements

For production-facing features, the engine must consider:

- validation of inputs
- safe handling of missing/partial data
- idempotency where messages/jobs may replay
- duplicate protection
- transactional integrity for financial/stock/order actions
- audit records for human decisions
- clear error states in UI
- rollback or disable path
- monitoring/log evidence
- RLS/security correctness

If a feature cannot meet these requirements yet, it must be marked PARTIAL or PLANNED, not BUILT_VALIDATED.

---

# 7. Manageability Requirements

The app must be easy for management and operators to control.

Important operational features should expose:

- status
- owner
- last update time
- next required action
- blocker reason
- audit trail
- search/filter
- export where useful
- role-based action controls
- safe manual override with audit

No important workflow should become a black box.

---

# 8. Business Generation Requirements

Business-generating features must be measured against real outcomes:

- faster customer response
- more orders captured
- fewer missed WhatsApp leads
- faster quotation/order creation
- better product discovery
- fewer wrong SKUs
- better distributor/client follow-up
- better stock/dispatch reliability
- better management visibility
- lower manual effort

A feature that looks advanced but does not improve these outcomes must be deprioritized.

---

# 9. “Best Possible App” Feature Standard

A best-in-class Oasis app should eventually include:

- central role-based admin
- product intelligence and catalogue governance
- WhatsApp/order intelligence
- sales order governance
- finance and credit controls
- dispatch/warehouse/gatekeeper controls
- traceability, labels, batch and expiry tracking
- management dashboards
- audit and compliance ledger
- integrations with providers and accounting tools
- high-quality search and filtering
- mobile-friendly operator workflows
- robust error recovery and observability
- safe AI assistance with human approval gates

But these must be built in controlled phases, not all at once.

---

# 10. Decision Rule

When choosing between two approaches, prefer the one that is:

1. safer for production,
2. cheaper in tokens/credits/time,
3. easier to validate,
4. easier to maintain,
5. less likely to create hidden data corruption,
6. closer to a real business outcome.

If these conflict, safety and correctness win first; business value and speed come next; aesthetics and convenience come after governance.
