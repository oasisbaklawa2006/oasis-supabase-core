# Phase 4.1f — Product Schema Reconciliation Design

**Date:** 2026-07-14  
**Status:** DESIGN ANALYSIS ONLY — No implementation yet  
**Scope:** Read-only design; all files analyzed; three options evaluated; recommendation provided

---

## Executive Summary

**Critical Finding:** The foundation baseline and legacy products migration collide at the CREATE TABLE level. Both unconditionally create `public.products`, but with fundamentally different schemas:

- **Foundation (20260101000000):** 137 columns + 3 constraints
- **Legacy (20260506044916):** 30 columns + RLS policies + other 10 tables
- **Subsequent ALTERs:** 28 more columns, ALL protected with IF NOT EXISTS guards

**Recommendation:** **OPTION C — Merged Baseline**
- Amend foundation baseline to include full 137 + 28 = 165-column products schema
- Reconcile legacy to NOT create products (other tables preserved)
- Leverage existing IF NOT EXISTS guards in ALTERs
- Provides clean, ordered, idempotent replay

**Risk Level:** MEDIUM (design is sound; requires careful amendment)  
**GO/NO-GO:** NO-GO for current foundation baseline; YES for reconciled version

---

## 1. Column Inventory Summary

| Category | Count | Details |
|----------|-------|---------|
| **Foundation CREATE** | 137 | Core products schema (pricing, packaging, customization, storage, metadata) |
| **Legacy CREATE** | 30 | Lightweight baseline (basic product info) |
| **Columns in BOTH** | 27 | Shared columns (COLLISION POINT) |
| **Legacy-only** | 3 | `b2b_price`, `export_price`, `updated_at` (at risk if superseded) |
| **Foundation-only** | 61 | New capabilities (pricing tiers, cost breakdown, customization, private label) |
| **Added via ALTERs** | 28 | Evolutionary columns (`archived_at`, `product_truth_snapshot`, pricing variants) |
| **ALTERs duplicating foundation** | 49 | SAFE (all protected with IF NOT EXISTS) |
| **TOTAL UNIQUE COLUMNS** | 168 | After deduplication |

---

## 2. Three Reconciliation Options

### Option A: Baseline Excludes Products (Legacy Creates)

**Approach:**
1. Remove `CREATE TABLE public.products` from foundation baseline (20260101000000)
2. Keep foundation's other 5 tables: categories, companies, users, orders, order_items
3. Keep legacy's products CREATE at 20260506044916
4. All subsequent ALTERs continue to extend the legacy-started products schema

**Pros:**
- ✅ No collision (foundation doesn't create products)
- ✅ No amendment to current foundation baseline
- ✅ Minimal diff for reconciliation

**Cons:**
- ❌ Foundation no longer provides **complete structural prerequisite** (products missing)
- ❌ Central's earliest migration depends on products existing; if foundation doesn't create it, the dependency is broken
- ❌ Fresh deployments get incomplete baseline; legacy products 30-column schema remains bottleneck
- ❌ Violates foundation baseline's semantic design (prerequisites for all migrations)
- ❌ Confuses future developers ("why isn't products in the foundation?")

**Salvage status:** Not recommended (architectural violation)

---

### Option B: Correctly Ordered Additive Migration

**Approach:**
1. Move foundation baseline to timestamp 20260801000000 (after all current migrations)
2. Keep it as `CREATE TABLE IF NOT EXISTS` (idempotent re-apply)
3. Apply order: legacy 20260506044916 → ALTERs → foundation 20260801000000
4. Foundation acts as "audit layer" verifying schema completeness

**Pros:**
- ✅ Avoids CREATE collision (applies IF NOT EXISTS after legacy)
- ✅ No amendment to foundation's SQL definition
- ✅ Foundation becomes schema verification layer

**Cons:**
- ❌ Breaks sealed-ordering invariant (foundation MUST apply first)
- ❌ Foundation loses its role as **prerequisite baseline**
- ❌ Violates the fundamental design intention
- ❌ Confuses future developers ("which is the real baseline?")
- ❌ Makes maintenance and debugging harder (prerequisite order is violated)

**Salvage status:** Not recommended (architectural violation)

---

### Option C: Merged Baseline (Recommended)

**Approach:**
1. **Phase 1 (Current):** Analyze and design the merged schema ← WE ARE HERE
2. **Phase 2 (Implementation):** 
   - Create new foundation baseline SQL that merges all 137 + 28 + legacy-only columns
   - Keep timestamp 20260101000000 (earliest)
   - Include products table with FULL 165+ column definition
   - Add explicit backfill defaults for columns that have no foundation-provided default
3. **Phase 3 (Reconciliation):**
   - Amend legacy migration (20260506044916) to NOT create products
   - Keep all other legacy tables (product_media, tags, catalogues, etc.)
   - Keep all downstream ALTERs (IF NOT EXISTS guards already present)
4. **Phase 4 (Validation):**
   - Disposable-branch replay against merged baseline + full chain
   - Verify all 6 validator checks + Central lineage
   - Confirm zero collisions, zero missing relations

**Merged Schema Includes:**

| Aspect | Source | Details |
|--------|--------|---------|
| **Core identity** | Foundation | id (uuid, PK, gen_random_uuid) |
| **Catalog** | Foundation | name, sku, product_name, short_name, category, category_id (FK), product_type, product_class |
| **Pricing (multi-tier)** | Foundation | mrp, price_per_kg, base_price, price_bulk, price_wholesale, price_horeca, price_b2b, price_special, plus per-unit variants |
| **Legacy pricing** | Legacy | b2b_price, export_price (preserved for backward compatibility) |
| **Costing** | Foundation | cost_per_pc, cost_per_kg, cost_per_primary_pack, cost_per_master_carton |
| **Packaging/dimensions** | Foundation | pack_size, carton_type, carton_qty, pcs_per_pack, pcs_per_carton, dimensions, weight variants |
| **Storage/handling** | Foundation | storage_type (CHECK), storage_instructions, temperature_requirement, thawing_instruction, frozen_shelf_life_days |
| **Customization** | Foundation | customization_allowed, customization_note, customization_caution |
| **Private label** | Foundation | private_label_allowed, private_label_moq, private_label_price, private_label_cost_per_unit, private_label_upfront_cost |
| **Allergens/nutrition** | Foundation | allergen_warnings, nutrition_facts, nutritional_info, ingredients |
| **Media/catalog** | Foundation | image_url, hero_image_url, visible_in_catalog, media_status, label_status |
| **Metadata** | Foundation | created_at, is_active, is_catalogue_ready, is_sample, department, production_department, settlement_unit |
| **Operational** | Foundation | operational_notes, pricing_notes, bom_required, bom_summary |
| **Legacy metadata** | Legacy | updated_at (preserved for backward compatibility) |
| **Evolutionary additions** | ALTERs | archived_at, archived_by, product_truth_snapshot, source_document, pricing variants, storage variants |

**Pros:**
- ✅ Single authoritative baseline (foundation 20260101000000)
- ✅ Resolves collision by design (products defined in one place)
- ✅ Preserves all semantics (legacy + foundation + ALTERs unified)
- ✅ Fresh deployments get complete 165+ column schema
- ✅ Existing legacy data can migrate with backfill
- ✅ Sealed-ordering invariant maintained (foundation applies first)
- ✅ Future developers understand baseline architecture
- ✅ IF NOT EXISTS guards in ALTERs make it safe (no-op if already exists)

**Cons:**
- ⚠️ Foundation baseline file becomes larger (165+ columns vs 137)
- ⚠️ Requires careful amendment (schema merge verification)
- ⚠️ Needs re-validation (disposable-branch replay of merged baseline)
- ⚠️ Phase 4.1d evidence becomes "foundation in isolation" (historical marker)

**Salvage status:** YES — Recommended (current foundation is not lost; becomes "Phase 4.1d isolated baseline"; merged version is "Phase 4.1f reconciled baseline")

---

## 3. Analysis of ALTER Migrations

### IF NOT EXISTS Protection Status

**ALL ALTER migrations use IF NOT EXISTS guards:**

| Migration | Column ADDs | Protected | Impact if Foundation Applied First |
|-----------|------------|-----------|-------------------------------------|
| 20260506053901 | 10 columns | ✓ All IF NOT EXISTS | Silent no-op (columns already exist) |
| 20260506093648 | 43 columns | ✓ All IF NOT EXISTS | Silent no-op (columns already exist) |
| 20260506164807 | 21 columns | ✓ All IF NOT EXISTS | Silent no-op (columns already exist) |
| 20260602120000 | 1 column | ✓ IF NOT EXISTS | Silent no-op (column already exists) |
| 20260603120000 | 2 columns | ✓ IF NOT EXISTS | Silent no-op (columns already exist) |

**Key Finding:** Because ALL ALTERs use IF NOT EXISTS, the migration chain is already **idempotent and safe** for either application order (legacy first OR foundation first). The IF NOT EXISTS guards mean:
- If foundation creates the column → ALTER no-ops silently ✓
- If legacy starts → ALTER adds → ALTERs skip duplicates ✓

This makes **Option C fully safe** with respect to downstream migrations.

---

## 4. Dependency Graph

### Creation Order (Current — COLLISION)

```
20260101000000 (foundation)
  ├─ categories (CREATE)
  ├─ companies (CREATE)
  ├─ users (CREATE)
  ├─ products (CREATE - 137 cols) ← COLLISION
  ├─ orders (CREATE)
  └─ order_items (CREATE)

20260506044916 (legacy)
  ├─ profiles (CREATE)
  ├─ user_roles (CREATE)
  ├─ functions & triggers
  ├─ products (CREATE - 30 cols) ← COLLISION ❌
  ├─ product_media (CREATE) → FK to products ✓
  ├─ tags, catalogues, hampers, ingredients, labels, ai_jobs, integration_settings (CREATE)
  └─ RLS policies
```

### Safe Order (Option C — MERGED)

```
20260101000000 (foundation - AMENDED to merged schema)
  ├─ categories (CREATE)
  ├─ companies (CREATE)
  ├─ users (CREATE)
  ├─ products (CREATE - 165+ cols, merged) ← RESOLVED ✓
  ├─ orders (CREATE)
  └─ order_items (CREATE)

20260506044916 (legacy - AMENDED to skip products CREATE)
  ├─ profiles (CREATE)
  ├─ user_roles (CREATE)
  ├─ functions & triggers
  ├─ [products CREATE REMOVED] ← WAS HERE
  ├─ product_media (CREATE) → FK to products ✓ (exists from foundation)
  ├─ tags, catalogues, hampers, ingredients, labels, ai_jobs, integration_settings (CREATE)
  └─ RLS policies

20260506053901 (ALTER - identity preserved)
  └─ ADD COLUMN ... IF NOT EXISTS (silent no-op for columns already in foundation)

20260506093648 (ALTER - identity preserved)
  └─ ADD COLUMN ... IF NOT EXISTS (silent no-op for columns already in foundation)

[15+ more migrations]
  └─ Same pattern: IF NOT EXISTS guards ensure idempotency
```

---

## 5. Files Requiring Change

### Foundation Baseline Amendment

**File:** `supabase/migrations/20260101000000_foundation_baseline_categories_companies_users_products_orders_order_items.sql`

**Current status:** 382 lines, 137-column products definition

**Required change:** Merge additional columns from:
1. Legacy CREATE: `b2b_price`, `export_price`, `updated_at`
2. Subsequent ALTERs (28 columns): `archived_at`, `archived_by`, `product_truth_snapshot`, `source_*`, pricing variants, etc.

**Result:** ~450-500 lines, 165+ column products definition

**Change type:** AMENDMENT (not replacement; preserve all foundation columns + add legacy + ALTER columns)

### Legacy Migration Reconciliation

**File:** `supabase/migrations/20260506044916_a42777fe-a715-4414-8231-49e51595634d.sql`

**Current status:** ~324 lines, creates 11 tables (including products)

**Required change:** Remove ONLY the `CREATE TABLE public.products (...)` block (lines 58–89, approximately 32 lines)

**Preserve:** All other 10 tables + all RLS policies + all functions + all triggers

**Change type:** SURGICAL EDIT (remove 32 lines; keep ~292 lines intact)

### ALTER Migrations (No Changes Required)

**Files:** All ALTER TABLE migrations already use IF NOT EXISTS

**Status:** No changes needed; they will work correctly with merged baseline

**Example:** 20260506053901 uses `ADD COLUMN IF NOT EXISTS` on all columns → safe

---

## 6. Data-Loss and Checksum Risks

### Data-Loss Risks

**Scenario A: Fresh Database**
- Current: Migration fails at 20260506044916 (collision)
- Merged: Succeeds; full 165+ column products created ✓
- Risk: **NONE** (fresh DB has no data to lose)

**Scenario B: Existing Legacy Database (30-column products)**
- Current: Foundation silently no-ops (IF NOT EXISTS); downstream failures
- Merged: Foundation attempts to ALTER existing table to add 135+ missing columns
- Requires: BACKFILL strategy for new columns (defaults provided)
- Risk: **MEDIUM** (backfill correctness; but reversible via backup)

### Checksum Risks

**Checksum integrity:**
- Foundation baseline file will change (amendment)
- Legacy baseline file will change (surgical removal of 32 lines)
- All other migrations unchanged
- New Phase 4.1d evidence (current) becomes historical marker
- New Phase 4.1f evidence documents merged baseline

**Impact:**
- Current Phase 4.1d commit (156282877f...) is VALID as "foundation in isolation"
- New reconciled commit (to be created) will have different SHA
- Old evidence is NOT invalidated; it's a valid snapshot of intermediate state

---

## 7. Complete Migration Chain Replay Plan

### Phase 4.1f Implementation (Future)

**Step 1: Foundation Amendment**
- Read current 20260101000000_foundation_baseline_...sql (137 columns)
- Merge in legacy-only columns: b2b_price, export_price, updated_at
- Merge in ALTER-added columns: archived_at, archived_by, product_truth_snapshot, source_*, pricing variants
- Preserve all CHECK constraints and FKs from foundation
- Result: Single CREATE TABLE products with ~165+ columns

**Step 2: Legacy Reconciliation**
- Edit 20260506044916_a42777fe-...sql
- Remove lines containing `CREATE TABLE public.products (...)` (approx. lines 58–89)
- Keep all other CREATE TABLE statements (profiles, user_roles, product_media, tags, etc.)
- Keep all functions, triggers, RLS policies
- Test that file is syntactically valid

**Step 3: Validation**
- Run all 6 validator checks on amended foundation
- Run sealed-ordering check (foundation still earliest)
- Disposable-branch replay:
  1. Create fresh disposable Supabase branch
  2. Apply amended foundation baseline → verify 165+ columns, 10+ tables, FKs
  3. Apply reconciled legacy migration → verify products not re-created, other 10 tables added, RLS policies
  4. Apply all 15+ subsequent ALTERs → verify IF NOT EXISTS guards work correctly, no columns added (already in foundation)
  5. Apply Central's earliest migration (RLS policies) → verify no missing-relation errors
  6. Confirm Central's lineage unblocked
  7. Delete branch

**Step 4: Evidence and Documentation**
- Create new PHASE_4_1F_RECONCILIATION_EVIDENCE_2026-07-14.md
- Document merged baseline design
- Record disposable-branch replay results
- Document exact file changes
- Confirm GO for review

---

## 8. GO/NO-GO Recommendation

### Current Foundation Baseline (Phase 4.1d)

**Status:** ❌ **NO-GO for merge**
- Collides with legacy migration at CREATE TABLE
- Fresh replay fails at 20260506044916
- Incomplete schema for full migration chain

**Reason:** The foundation baseline is valid in isolation but incompatible with legacy migration lineage.

### Reconciled Foundation Baseline (Phase 4.1f)

**Recommendation:** ✅ **YES-GO for implementation**

**Conditions:**
1. ✅ Amendment completed (foundation + legacy-only + ALTER columns merged)
2. ✅ Legacy migration surgically edited (products CREATE removed)
3. ✅ All 6 validator checks pass on amended baseline
4. ✅ Disposable-branch replay succeeds (foundation → legacy → ALTERs → Central)
5. ✅ No conflicts, no missing relations, no data loss
6. ✅ Evidence document created and verified

**Path Forward:**
1. This design analysis (Phase 4.1f-a) ← COMPLETE
2. Create amend foundation and reconcile legacy (Phase 4.1f-b)
3. Validate disposable-branch replay (Phase 4.1f-c)
4. Final evidence and review-ready status (Phase 4.1f-d)

---

## 9. Summary Table

| Aspect | Current | Reconciled | Status |
|--------|---------|-----------|--------|
| **Foundation CREATE** | 137 cols | 165+ cols | AMENDED |
| **Legacy products CREATE** | Collision | Removed | SURGICAL |
| **Collision resolved** | ❌ NO | ✅ YES | RESOLVED |
| **Fresh DB replay** | ❌ FAILS | ✅ SUCCEEDS | SAFE |
| **Legacy DB migration** | Incomplete | ✓ Complete | SAFE |
| **IF NOT EXISTS guards** | ✓ Protected | ✓ Protected | SAFE |
| **Sealed-ordering maintained** | ✓ YES | ✓ YES | MAINTAINED |
| **Validator checks** | 6/6 | 6/6 (after amendment) | CHECKABLE |
| **Central lineage** | BLOCKED | UNBLOCKED | RESOLVED |
| **Data preservation** | ❌ LOST | ✅ PRESERVED | SAFE |
| **GO for merge** | ❌ NO-GO | ✅ YES-GO (post-implementation) | PENDING |

---

**Design Analysis Complete:** 2026-07-14  
**Method:** Read-only inventory, conflict analysis, three-option evaluation  
**Recommendation:** Proceed to Phase 4.1f-b (Implementation) with Option C (Merged Baseline)  
**Next Deliverable:** Amended foundation baseline + reconciled legacy migration + disposable-branch replay evidence

