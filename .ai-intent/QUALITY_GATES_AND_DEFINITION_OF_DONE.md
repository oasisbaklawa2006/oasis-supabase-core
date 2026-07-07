# Quality Gates and Definition of Done

Generated: 2026-07-07
Purpose: Mandatory completion standard for Oasis enterprise app features.

A feature is not “done” because code was written. It is done only when the correct evidence exists.

---

# 1. Status Rules

Use these statuses honestly:

- PLANNED: intended, not implemented
- NOT_BUILT: explicitly absent
- PARTIAL: some pieces exist, missing full workflow/evidence
- BUILT_NEEDS_EVIDENCE: likely built but not freshly proven
- BUILT_VALIDATED: proven end-to-end with evidence
- BLOCKED: cannot proceed until dependency/decision is resolved
- UNKNOWN_VALIDATE: must inspect before claiming status

Never mark BUILT_VALIDATED without proof.

---

# 2. Minimum Definition of Done for Any Feature

A feature must satisfy all applicable checks:

1. Feature is listed in FEATURE_REGISTRY.md
2. Screen/route is listed in SCREEN_REGISTRY.md where applicable
3. Owner repo is clear
4. Source of truth table/function is clear
5. UI path works for intended role
6. Backend path works
7. RLS/auth works for real user
8. Error state is handled
9. Empty/loading state is handled
10. Audit trail exists where business-critical
11. No secret values are committed
12. No unrelated files are changed
13. Tests or manual evidence are recorded
14. Handover docs are updated

---

# 3. Higher Gate for Money/Stock/Order Features

Any feature touching sales orders, invoices, finance, dispatch, stock, payment terms, credit, or audit must additionally prove:

- readiness gates are respected
- irreversible actions need explicit approval
- duplicate submissions are prevented
- mutations are transactional or recoverable
- operator identity is recorded
- timestamps are recorded
- rollback/correction route exists or is documented
- no AI-only decision creates financial/stock truth

---

# 4. Database Gate

Before database changes:

1. Inspect current schema
2. Check dependencies
3. Prefer idempotent migration
4. Preserve data
5. Preserve RLS
6. Add indexes only with reason
7. Validate with read-only SQL after apply
8. Record migration purpose and risk

Never guess column names in production SQL.

---

# 5. Edge Function / Integration Gate

Before deploying an edge function or integration change:

1. Identify owner repo
2. Confirm function slug
3. Confirm env vars/secret names only, not values
4. Run dry-run if available
5. Validate logs
6. Validate database result
7. Confirm disable/rollback path
8. Record evidence

Protected warning: do not deploy or modify whatsapp-webhook from AI Studio.

---

# 6. UI Gate

Before marking UI complete:

- route loads
- role access works
- loading state works
- empty state works
- error state works
- action buttons are gated
- modals/dropdowns/z-index work
- mobile/narrow screen is acceptable for operators
- no console errors from the target flow
- data shown is from correct source of truth

---

# 7. Performance Gate

For screens likely to grow:

- avoid loading unbounded rows
- use pagination/limits/search
- index common filters
- avoid N+1 calls
- avoid large JSON payloads where not needed
- cache only with safe invalidation
- keep expensive AI operations out of normal page load

---

# 8. Security Gate

Before shipping:

- no service role key in frontend
- no secret values in markdown/repo
- RLS remains enabled where required
- role checks use approved functions/policies
- audit tables are not user-editable unless explicitly designed
- provider tokens remain in secret manager
- exposed secrets are scheduled for rotation

---

# 9. Regression Gate

Every change must state what existing flow could be broken and how it was checked.

At minimum, protected WhatsApp/bridge/draft flow must remain untouched unless specifically being tested.

---

# 10. Completion Statement Template

When marking work complete, the AI engine must report:

- feature changed
- files changed
- database objects changed
- tests/queries run
- evidence observed
- remaining risk
- whether registries were updated
- whether secrets were touched
- next safe action
