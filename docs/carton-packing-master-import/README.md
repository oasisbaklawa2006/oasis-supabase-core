# Carton packing master — import package (draft, not approved, not run)

| File | Purpose |
|---|---|
| `carton_configurations_draft.csv` / `import_carton_configurations_draft.sql` | the three owner-specified configurations as **draft** rows (capacity, inner pack). |
| `carton_physical_reference.csv` | owner-confirmed internal carton dimensions (inches and mm), primary container dimensions, arrangement status, evidence class and trial status. Reference only: the governed tables store no dimensions. |
| `product_packing_profiles_template.csv` | header only. SKU mappings, packing groups and units come from Operations with evidence; none are invented. |

Evidence classes are kept apart: owner-confirmed (internal carton dimensions, RTC1×10 identity and arrangement), supplier-listing (666 and 888 primary container dimensions, approximate), factory photographs (FP-01…FP-11), calculated geometry (feasibility report) and physical trial evidence (**none yet**). The 40 mm RTC tray is outside this release.
**Approval path:** Operations returns evidence → Core approver sets `approval_status='approved'` with `approved_by`, `approved_at` and `evidence_ref` (the database refuses approval without them) → rows become visible to eligible buyers through the projections only for products with an approved, unit-matching price.
Verified on a replay of the Core schema (real PostgreSQL 16): the script inserts three draft rows and `buyer_carton_configurations_v1()` returns nothing to any buyer until a row is approved.
