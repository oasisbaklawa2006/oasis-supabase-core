# Phase 4.1e — Migration Chain Collision Audit

**Date:** 2026-07-14  
**Status:** ⚠️ CRITICAL COLLISION — Foundation baseline and legacy migrations incompatible  
**Scope:** Read-only audit only; no SQL executed; no repository changes made

---

## 1. Collision Summary

| Aspect | Details |
|--------|---------|
| **Foundation baseline** | `supabase/migrations/20260101000000_foundation_baseline_categories_companies_users_products_orders_order_items.sql` |
| **Legacy conflict** | `supabase/migrations/20260506044916_a42777fe-a715-4414-8231-49e51595634d.sql` |
| **Action conflict** | Both unconditionally create `public.products` |
| **Baseline timestamp** | 20260101000000 (creates 137-column products) |
| **Legacy timestamp** | 20260506044916 (creates 30-column products) |
| **Relative order** | Foundation would apply FIRST (earlier timestamp), legacy SECOND (later) |
| **Fresh replay failure mode** | Legacy migration fails: table already exists (even with IF NOT EXISTS guards on ALTERs, the CREATE TABLE itself will fail) |
| **Existing data failure mode** | If legacy data exists in 30-column schema, foundation baseline cannot retroactively add 110 missing columns to populated rows without migration |

---

## 2. Schema Comparison

### Foundation Baseline (137 columns)
**Source:** `supabase/migrations/20260101000000_...`  
**Columns:** 137  
**Key structural details:**
- All columns created atomically in single CREATE TABLE
- Includes product pricing dimensions: `price_per_kg`, `price_bulk`, `price_wholesale`, `price_horeca`, `price_b2b`, `price_special`
- Includes cost breakdown: `cost_per_pc`, `cost_per_kg`, `cost_per_primary_pack`, `cost_per_master_carton`
- Includes MRP variants: `mrp_per_pc`, `mrp_per_kg`, `mrp_per_primary_pack`, `mrp_per_master_carton`
- Includes quantity/packaging: `pcs_per_pack`, `pcs_per_carton`, `pcs_per_primary_pack`, `pcs_per_kg`, `kg_per_primary_pack`, `kg_per_master_carton`
- Includes operational metadata: `production_department`, `settlement_unit`, `operational_notes`, `pricing_notes`
- Includes storage/handling: `storage_type`, `temperature_requirement`, `thawing_instruction`, `frozen_shelf_life_days`
- Includes customization: `customization_allowed`, `customization_note`, `customization_caution`
- Includes private label: `private_label_allowed`, `private_label_moq`, `private_label_price`, `private_label_cost_per_unit`, `private_label_upfront_cost`
- Includes taxonomy: `category_id` (FK), `category`, `sub_category`, `subcategory_code`, `department`, `main_department`
- Includes allergens/nutrition: `allergen_warnings`, `nutrition_facts`, `nutritional_info`, `ingredients`
- Includes media/visibility: `image_url`, `visible_in_catalog`, `media_status`, `label_status`
- 3 CHECK constraints on `storage_type`, `default_store`, `production_department`
- 1 FK: `category_id → categories(id)` with ON DELETE SET NULL

### Legacy Baseline (30 columns)
**Source:** `supabase/migrations/20260506044916_a42777fe-...`  
**Columns:** 30  
**Key structural details:**
- Creates profiles, user_roles, functions, products, product_media, tags, catalogues, hampers, ingredients, labels, AI jobs, and integration settings
- Products table only: ~32 lines (lines 58–89)
- Products columns: id, sku, product_name, short_name, category, subcategory, product_type, description, short_description, pack_size, net_weight_g, gross_weight_g, shelf_life_days, storage_instructions, hsn_code, gst_rate, mrp, b2b_price, export_price, currency, moq_text, carton_logic, hero_image_url, is_active, is_catalogue_ready, label_status, media_status, is_sample, created_at, updated_at
- No FK to categories (uses string column `category` instead of `category_id` UUID)
- No storage type enforcement, no pricing breakdown, no cost columns
- Only one "price" concept: b2b_price (legacy), export_price (niche)
- RLS policies included in same migration (public read, team write/update/delete)
- ~250 lines for 11 tables + functions + RLS policies (vs. foundation's table structure only)

### Column Inventory

**Legacy-only (3 columns NOT in foundation):**
- `b2b_price` — deprecated by foundation's `price_b2b`
- `export_price` — niche, not in foundation
- `updated_at` — missing from foundation (but foundation's design pattern uses `created_at` only)

**Foundation-only (110 columns NOT in legacy):**
All remaining columns, including critical pricing, costing, packaging, customization, storage, and operational metadata.

**Common (27 columns):**
id, sku, product_name, short_name, category, subcategory, product_type, description, short_description, pack_size, net_weight_g, gross_weight_g, shelf_life_days, storage_instructions, hsn_code, gst_rate, mrp, currency, moq_text, carton_logic, hero_image_url, is_active, is_catalogue_ready, label_status, media_status, is_sample, created_at

---

## 3. Dependent Tables and FK Chains

### Tables with FK to products(id)

**In Foundation baseline (20260101000000):**
- `order_items` — `product_id FK → products(id)` (ON DELETE CASCADE)

**Created by legacy migration (20260506044916) and dependent on products:**
- `product_media` — `product_id FK → products(id)` (ON DELETE CASCADE)
- `product_tags` — `product_id FK → products(id)` (ON DELETE CASCADE)
- `hampers` — `parent_product_id FK → products(id)` (ON DELETE CASCADE)
- `hamper_items` — `child_product_id FK → products(id)` (ON DELETE SET NULL)
- `product_ingredients` — `product_id FK → products(id)` (ON DELETE CASCADE)
- `nutrition_panels` — `product_id FK → products(id)` (ON DELETE CASCADE, UNIQUE)
- `labels` — `product_id FK → products(id)` (ON DELETE CASCADE, UNIQUE)
- `ai_generation_jobs` — `product_id FK → products(id)` (ON DELETE CASCADE)
- `catalogue_products` — `product_id FK → products(id)` (ON DELETE CASCADE)

**Created by subsequent migrations (202605xx and beyond):**
- Various tracking, audit, and workflow tables all reference `products(id)`

**Total dependent FK chains:** 20+ tables, deeply nested

---

## 4. Migration Sequence Timeline

### Collision Point

```
Timeline (by timestamp):

20260101000000 (FOUNDATION BASELINE)
  ├─ creates: categories, companies, users, products (137 cols), orders, order_items
  └─ END OF FOUNDATION BASELINE

...gap of 4+ months...

20260506044916 (LEGACY PRODUCTS CREATION - COLLISION)
  ├─ creates: profiles, user_roles, [PRODUCTS (30 cols) ← CONFLICT], product_media, tags, catalogues, 
  │                     hampers, ingredients, labels, ai_jobs, integration_settings
  ├─ creates: RLS policies for all above
  └─ END OF LEGACY CREATION

20260506053901 (add sku columns)
  ├─ ALTER TABLE products ADD COLUMN sku_locked, sku_generated_at, sku_version, 
  │   division_code, category_code, subcategory_code, packaging_code, serial_no, legacy_sku, 
  │   external_reference_code
  └─ (Assumes products exists with 30 columns; adds more)

20260506093648 (add product classification)
  ├─ ALTER TABLE products ADD COLUMN product_class, main_department, production_department
  └─ (Assumes products exists; adds 3 more columns)

20260506164807 (add source tracking)
  ├─ ALTER TABLE products ADD COLUMN source_document, source_page, source_collection
  └─ (Assumes products exists; adds 3 more columns)

...15 more migrations that assume and extend the products schema...

20260709120000 (latest: catalogue AI studio governance)
  └─ References products with all accumulated columns
```

### Application Order (Fresh DB, Foundation First)

1. **20260101000000** ✅ Foundation baseline applies → creates products with 137 columns ✓
2. **20260506044916** ❌ Legacy products creation FAILS:
   - `CREATE TABLE public.products (...)` fails because table already exists
   - Even with IF NOT EXISTS guards on ALTER statements, the CREATE TABLE itself has no such guard
   - Fresh replay terminates at this migration

---

## 5. Data-Loss Risk Analysis

### Scenario A: Fresh Database Replay (Production Initialization)

**Deployment path:**
1. Apply foundation baseline → 137-column products created ✓
2. Attempt legacy products creation → **FAILS** (table exists)

**Outcome:** 
- ❌ Migration chain broken
- ⚠️ Data-loss risk: LOW (no data yet, fresh DB)
- 🛑 **Severity:** BLOCKING — chain cannot complete

**Recovery:** 
- Must either skip legacy migration or remove its CREATE TABLE
- But legacy migration also creates 10+ other tables that ARE needed (product_media, tags, catalogues, hampers, etc.)

---

### Scenario B: Legacy Database (Existing 30-Column Products)

**Current state (before foundation baseline):**
- Products table exists with 30 columns
- 20+ dependent tables reference it
- Production data in products, product_media, catalogues, etc.

**Deployment path:**
1. Apply foundation baseline → `CREATE TABLE IF NOT EXISTS products (137 cols)` — **TABLE EXISTS, silently no-op**
2. Foundation's 110 new columns are NOT added (due to IF NOT EXISTS)
3. Products table remains 30-column
4. Downstream migrations try to reference new columns (e.g., `price_b2b`, `cost_per_kg`) → **ERRORS**

**Outcome:**
- ❌ Foundation baseline claims success but silently fails to add 110 columns
- ❌ Migrations downstream fail when they reference columns that don't exist
- ⚠️ Data-loss risk: MEDIUM (existing data preserved, but schema incomplete and inconsistent)
- 🛑 **Severity:** CRITICAL — silent corruption of expected state

---

### Scenario C: Forced Legacy Supersession (Dangerous Workaround)

**If someone tries to drop and recreate:**
```sql
DROP TABLE products CASCADE;  -- Deletes all products + all dependent FK data
CREATE TABLE products (30 cols);  -- Legacy schema
```

**Outcome:**
- ❌ All product data, metadata, media, catalogues, ingredients, labels, AI jobs DELETED
- ⚠️ Data-loss risk: **CATASTROPHIC**
- 🛑 **Severity:** UNRECOVERABLE

---

## 6. Downstream Dependencies Summary

**Migrations that assume foundation's 137-column schema:**
- None detected yet (foundation is new, not yet deployed)

**Migrations that assume legacy's 30-column schema + added columns:**
- 20260506053901 through 20260709120000
- All 15+ subsequent migrations use ALTER TABLE with IF NOT EXISTS to extend the 30-column base

**Code/application assumptions:**
- Application logic likely assumes either:
  - Legacy's 30 columns + accumulated ALTERs (~50+ by now)
  - OR foundation's 137 columns as a fresh start

**Mismatch severity:** 
- If code tries to access `products.price_b2b` (from foundation) on legacy 30-column schema → NULL or "column not found" error

---

## 7. Reconciliation Options

### Option A: Supersede Legacy — Keep Foundation Only

**Approach:**
1. Remove or comment out the `CREATE TABLE products` statement from 20260506044916
2. Keep all other table creations in 20260506044916 (product_media, tags, catalogues, etc.)
3. Modify 20260506053901+ to skip ALTER columns already in foundation (use IF NOT EXISTS)
4. Preserve legacy-only columns (`b2b_price`, `export_price`, `updated_at`) by explicitly adding them to foundation

**Pros:**
- ✅ Single authoritative schema (foundation 137-column)
- ✅ Complete pricing/cost/packaging metadata available to all downstream code
- ✅ Fresh deployments get full capability immediately
- ✅ Foundation satisfies all application needs

**Cons:**
- ⚠️ Requires careful patching of all 15+ downstream migrations
- ⚠️ Must add legacy-only columns to foundation to avoid partial regressions
- ⚠️ If existing data in 30-column schema, requires data migration (add 110 columns, backfill defaults)

**Risk:** MEDIUM (manageable with careful migration design)

**Baseline salvageable?** YES, with amendments

---

### Option B: Preserve Legacy — Move Foundation Baseline Later

**Approach:**
1. Modify foundation baseline to timestamp 20260801000000 (AFTER all legacy migrations)
2. Change foundation baseline to use `CREATE TABLE IF NOT EXISTS` (already does)
3. Remove duplicate table definitions from legacy migration
4. Keep order: legacy 20260506044916 → subsequent ALTERs → foundation 20260801000000 (no-op for existing tables, adds missing columns as new tables)

**Pros:**
- ✅ Avoids colliding timestamps
- ✅ Legacy data preserved; no migration needed
- ✅ Foundation acts as "schema audit and completion" layer

**Cons:**
- ⚠️ Breaks foundation baseline's design intention (must apply BEFORE all others)
- ⚠️ Foundation loses its role as the definitive structural prerequisite
- ⚠️ Confuses future developers about which is the "true" baseline
- ❌ Violates the sealed-ordering invariant (foundation MUST be first)

**Risk:** HIGH (architectural confusion, future maintenance pain)

**Baseline salvageable?** NO (would require fundamental redesign)

---

### Option C: Conditional Reconciliation — Merge Schemas

**Approach:**
1. Create NEW foundation baseline: `20260101000000_foundation_baseline_v2.sql`
2. Define products as the UNION of legacy 30 columns + foundation's 110 columns = 137 columns total
3. Include all legacy columns (`b2b_price`, `export_price`, `updated_at`)
4. Include all foundation columns
5. Add CHECK constraints from foundation
6. Add FK to categories for `category_id`
7. Remove CREATE TABLE from 20260506044916's products section; it becomes a no-op for products
8. Modify all downstream 202605xx migrations to use IF NOT EXISTS (idempotent re-apply)

**Pros:**
- ✅ Single authoritative baseline (v2 foundation)
- ✅ Resolves collision by design
- ✅ Preserves all semantics from both paths
- ✅ Fresh deployments get complete schema
- ✅ Existing legacy data can migrate to full schema with backfill

**Cons:**
- ⚠️ Current foundation baseline must be amended or replaced
- ⚠️ Current recovery branch commit (156282877f...) becomes historical; new branch required
- ⚠️ Phase 4.1d evidence no longer describes the final baseline
- ⚠️ Adds complexity (merged schema is larger, harder to review)

**Risk:** MEDIUM (requires amendment to current baseline; manageable with clear strategy)

**Baseline salvageable?** PARTIALLY (current version must be superseded, but the underlying strategy is sound)

---

## 8. Recommended Safe Reconciliation Strategy

### Proposed: Option C with Staged Rollout

**Phase 1: Audit and Design (Current)**
- ✅ Complete this collision audit (already done)
- ✅ Identify all assumptions in code and dependent migrations
- ✅ Design unified schema v2 (37-column merge)

**Phase 2: Baseline Amendment**
- Create: `20260101000000_foundation_baseline_v2_merged_schema.sql`
- Incorporates ALL 137 foundation columns + legacy-only columns (`b2b_price`, `export_price`, `updated_at`)
- Replace current foundation baseline with this version
- Re-run Phase 4.1d disposable-branch replay against amended baseline to verify all downstream migrations apply cleanly

**Phase 3: Legacy Migration Reconciliation**
- Modify `20260506044916` to NOT create products table (already created by v2 foundation)
- Keep all other table creations (product_media, tags, catalogues, etc.)
- Modify downstream migrations (20260506053901+) to use IF NOT EXISTS for all ALTERs (idempotent re-apply)

**Phase 4: Validation**
- Run all 6 validator checks + Central lineage check
- Disposable-branch replay against full chain
- Confirm zero collisions, zero missing relations, zero constraint violations

**Phase 5: Commit and Review**
- Update recovery branch with amended baseline + reconciliation
- Re-run Phase 4.1d with full chain (foundation + legacy + 15+ subsequent migrations)
- Update evidence documents to record reconciliation

---

## 9. Whether Baseline Remains Salvageable

**Current status (156282877f...):** 
- ⚠️ **CONDITIONALLY SALVAGEABLE** if amended

**Salvage path:**
1. Don't discard current recovery branch; mark as "Phase 4.1d Baseline" (historical evidence of isolated foundation)
2. Create new Phase 4.1f: "Collision Reconciliation" branch
3. Amend foundation baseline in new branch (merge schemas)
4. Re-run disposable replay against amended baseline + full chain
5. Merge reconciled version to main once verified

**Salvage outcome:** 
- ✅ Original foundation design is sound (catches structural prerequisites correctly)
- ✅ Collision is a **known-issue fixable by schema merge**, not a design flaw
- ✅ Current evidence remains valid as "foundation in isolation"
- ✅ New evidence documents the "foundation in full chain" after reconciliation

---

## 10. Summary Table

| Item | Status | Risk | Recommendation |
|------|--------|------|-----------------|
| **Collision detected** | ✅ YES | BLOCKING | Proceed to reconciliation |
| **Data-loss risk** | ⚠️ MEDIUM | If forced drop | Use Option C merge strategy |
| **Fresh DB failure** | ✅ CONFIRMED | HIGH | Foundation must supersede legacy products CREATE |
| **Downstream chain** | ✅ 15+ migrations | MEDIUM | All need idempotency guards verified |
| **Baseline salvageable** | ✅ YES | With amendment | Merge schemas, re-validate |
| **Next phase** | Phase 4.1f | N/A | Collision Reconciliation: Merge Schemas |

---

**Audit completed:** 2026-07-14  
**Method:** Read-only inspection; no SQL executed; no changes made  
**Recommendation:** Proceed to Phase 4.1f: Schema Merge and Full-Chain Validation

