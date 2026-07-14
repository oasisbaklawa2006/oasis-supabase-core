-- Foundation baseline: categories, companies, users, products, orders, order_items
--
-- Purpose: this repo's tracked migration lineage (both this repo's own files
-- and Oasis-Baklawa-Central's) assumes these six tables already exist -- the
-- earliest tracked migration anywhere in the ecosystem (Central,
-- 20260316122451_bbadbd7b-....sql) opens with `CREATE POLICY ... ON
-- public.orders ... SELECT users.company_id FROM users WHERE users.id =
-- auth.uid()`, with no preceding CREATE TABLE for either relation anywhere in
-- tracked history. A fresh Supabase project/branch replaying the tracked
-- chain from empty fails at that very first migration. This file captures
-- the minimal structural prerequisite -- tables, primary keys, foreign keys,
-- CHECK constraints, and indexes only -- needed to make that chain
-- replayable, sourced from a read-only introspection of live production
-- (tcxvcatsqqertcnycuop) captured 2026-07-14. See
-- docs/recovery/PHASE_4_1B_FOUNDATION_BASELINE_EVIDENCE_2026-07-14.md for
-- the full capture method, deviations, and exclusions.
--
-- Scope: structural (tables/keys/indexes) only. Deliberately excludes RLS,
-- policies, grants, triggers, functions, storage, and all seed/data
-- statements -- those are separate, already-existing concerns owned
-- elsewhere in this repo's migration history, not part of this baseline.
--
-- Ordering: this migration is timestamped 20260101000000, earlier than every
-- other tracked migration in this repo and in Oasis-Baklawa-Central (whose
-- earliest is 20260316122451), so a fresh `supabase db reset`/branch replay
-- applies it first, in dependency order, before anything that assumes these
-- tables exist.
--
-- A genuine circular foreign-key dependency exists between companies and
-- users (companies.account_manager_id -> users.id, users.company_id ->
-- companies.id). This is resolved by creating companies.account_manager_id
-- as a plain column with no FK constraint, then adding the constraint via a
-- guarded ALTER TABLE once users exists (see step 4 below).
--
-- orders.closed_by and orders.finance_verified_by reference auth.users(id)
-- (Supabase's built-in auth schema), not public.users -- auth.users is
-- provisioned by Supabase itself in every project and is never created by
-- an application migration; no action is required here for it to exist.

-- ---------------------------------------------------------------------------
-- Step 1: categories (no dependencies; self-referential parent_id is safe
-- within a single CREATE TABLE)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.categories (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  parent_id uuid,
  CONSTRAINT categories_pkey PRIMARY KEY (id),
  CONSTRAINT categories_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.categories(id) ON DELETE SET NULL
);

-- ---------------------------------------------------------------------------
-- Step 2: companies (account_manager_id column created here WITHOUT its FK
-- constraint -- see step 4 for why)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.companies (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  business_name text NOT NULL,
  gst_number text,
  business_volume text,
  website text,
  credit_limit numeric DEFAULT 0,
  wallet_balance numeric DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  status text DEFAULT 'pending'::text,
  current_balance numeric DEFAULT 0,
  discount_percentage numeric DEFAULT 0,
  preferred_courier text,
  courier_account_number text,
  allow_credit boolean DEFAULT false,
  account_manager_id uuid,
  price_tier text DEFAULT 'B2B'::text,
  phone text,
  fssai_number text,
  registered_address text,
  payment_terms text NOT NULL DEFAULT 'prepaid'::text,
  is_frozen boolean NOT NULL DEFAULT false,
  total_outstanding numeric NOT NULL DEFAULT 0,
  rescue_payment_date timestamptz,
  settlement_deadline timestamptz,
  CONSTRAINT companies_pkey PRIMARY KEY (id),
  CONSTRAINT companies_credit_limit_nonneg CHECK ((credit_limit IS NULL) OR (credit_limit >= (0)::numeric)),
  CONSTRAINT companies_credit_limit_non_negative CHECK (credit_limit >= (0)::numeric),
  CONSTRAINT companies_payment_terms_check CHECK (payment_terms = ANY (ARRAY['prepaid'::text, 'credit'::text]))
);

-- ---------------------------------------------------------------------------
-- Step 3: users (depends on companies existing for company_id FK)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.users (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id uuid,
  name text,
  email text,
  phone text,
  role text NOT NULL,
  created_at timestamptz DEFAULT now(),
  full_name text,
  mobile_number text,
  department text,
  designation text,
  is_active boolean DEFAULT true,
  joined_at timestamptz,
  preferred_language text DEFAULT 'en'::text,
  invite_status text DEFAULT 'active'::text,
  commission_rate_percentage numeric DEFAULT 2.0,
  has_seen_tutorial boolean DEFAULT false,
  is_sales_executive boolean NOT NULL DEFAULT false,
  secondary_phones text[] DEFAULT ARRAY[]::text[],
  deleted_at timestamptz,
  CONSTRAINT users_pkey PRIMARY KEY (id),
  CONSTRAINT users_email_key UNIQUE (email),
  CONSTRAINT users_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Step 4: deferred circular FK -- companies.account_manager_id -> users.id,
-- added only now that users exists. Guarded so re-running this migration
-- against an already-baselined database is a no-op.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'companies_account_manager_id_fkey'
  ) THEN
    ALTER TABLE public.companies
      ADD CONSTRAINT companies_account_manager_id_fkey
      FOREIGN KEY (account_manager_id) REFERENCES public.users(id);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Step 5: products (depends on categories existing for category_id FK).
-- Full 137-column structural contract captured verbatim from a live,
-- read-only information_schema.columns query against tcxvcatsqqertcnycuop on
-- 2026-07-14 -- not hand-transcribed. See the evidence document for the
-- exact query.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.products (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  category_id uuid,
  price_per_kg numeric DEFAULT 0,
  pack_size text,
  carton_type text,
  storage_type text,
  description text,
  shelf_life text,
  image_url text,
  created_at timestamptz DEFAULT now(),
  is_active boolean NOT NULL DEFAULT true,
  category text NOT NULL,
  sku text NOT NULL,
  mrp numeric,
  wholesale_price numeric,
  weight_per_pc_grams numeric,
  net_weight_grams numeric,
  moq numeric DEFAULT 1,
  packs_per_master_carton numeric,
  hsn_code text NOT NULL,
  gst_percentage numeric,
  dietary_tags text[],
  sub_category text,
  department text,
  base_price numeric DEFAULT 0,
  price_bulk numeric DEFAULT 0,
  price_wholesale numeric DEFAULT 0,
  price_horeca numeric DEFAULT 0,
  price_b2b numeric DEFAULT 0,
  price_special numeric DEFAULT 0,
  uom text DEFAULT 'Pack'::text,
  avg_weight_per_pc numeric,
  avg_weight_per_pack numeric,
  packs_per_carton numeric,
  moq_packs numeric DEFAULT 1,
  private_label_moq numeric,
  private_label_price numeric,
  nutrition_facts text,
  mrp_per_pc numeric,
  festival_tags text,
  pcs_per_master_carton numeric,
  primary_pack_weight_kg numeric NOT NULL DEFAULT 0,
  gst_rate numeric DEFAULT 5,
  ingredients text,
  nutritional_info jsonb,
  allergen_warnings text,
  shelf_life_days integer,
  gross_weight_grams integer,
  storage_instructions text,
  barcode_sku text,
  default_store text DEFAULT 'ready_goods'::text,
  production_department text,
  settlement_unit text DEFAULT 'KG'::text,
  visible_in_catalog boolean NOT NULL DEFAULT true,
  weight_per_box_kg numeric,
  grams_per_piece numeric,
  aliases text[] DEFAULT '{}'::text[],
  product_family text,
  dimensions text,
  material text,
  gross_weight_kg numeric,
  bom_summary text,
  cost_per_pc numeric DEFAULT 0,
  cost_per_kg numeric DEFAULT 0,
  cost_per_primary_pack numeric DEFAULT 0,
  cost_per_master_carton numeric DEFAULT 0,
  mrp_per_kg numeric DEFAULT 0,
  mrp_per_primary_pack numeric DEFAULT 0,
  mrp_per_master_carton numeric DEFAULT 0,
  price_b2b_per_pack numeric DEFAULT 0,
  price_b2b_per_carton numeric DEFAULT 0,
  pcs_per_primary_pack numeric DEFAULT 0,
  pcs_per_kg numeric DEFAULT 0,
  kg_per_primary_pack numeric DEFAULT 0,
  kg_per_master_carton numeric DEFAULT 0,
  retail_uom text DEFAULT 'pc'::text,
  b2b_uom text DEFAULT 'kg'::text,
  bom_required boolean NOT NULL DEFAULT false,
  carton_logic text,
  carton_qty numeric,
  carton_uom text,
  fixed_carton_required boolean DEFAULT false,
  moq_value numeric,
  moq_uom text,
  moq_text text,
  primary_uom text,
  pricing_notes text,
  operational_notes text,
  category_code text,
  subcategory_code text,
  division_code text,
  packaging_code text,
  serial_no numeric,
  legacy_sku text,
  external_reference_code text,
  product_name text,
  short_name text,
  product_type text,
  product_class text,
  short_description text,
  currency text DEFAULT 'INR'::text,
  hero_image_url text,
  label_status text DEFAULT 'draft'::text,
  media_status text DEFAULT 'missing'::text,
  sku_locked boolean DEFAULT true,
  main_department text,
  increment_value numeric,
  increment_uom text,
  master_carton_qty numeric,
  master_carton_uom text,
  dimension_l_cm numeric,
  dimension_w_cm numeric,
  dimension_h_cm numeric,
  product_dimensions_cm text,
  pcs_per_pack numeric,
  pcs_per_carton numeric,
  net_weight_g numeric,
  gross_weight_g numeric,
  private_label_allowed boolean DEFAULT false,
  private_label_moq_uom text,
  private_label_cost_per_unit numeric,
  private_label_upfront_cost numeric,
  customization_allowed boolean DEFAULT false,
  customization_note text,
  customization_caution text,
  frozen_shelf_life_days integer,
  post_processing_shelf_life_days integer,
  temperature_requirement text,
  thawing_instruction text,
  material_type text,
  color_finish_notes text,
  is_catalogue_ready boolean DEFAULT false,
  is_sample boolean DEFAULT false,
  moq_rule_type text,
  subcategory text,
  unit_conversion_note text
,
  CONSTRAINT products_pkey PRIMARY KEY (id),
  CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL,
  CONSTRAINT products_storage_type_check CHECK (storage_type = ANY (ARRAY['ambient'::text, 'cool'::text, 'frozen'::text])),
  CONSTRAINT products_default_store_check CHECK (default_store = ANY (ARRAY['ready_goods'::text, 'packing_assembly'::text, '3rd_party'::text])),
  CONSTRAINT products_production_department_check CHECK ((production_department IS NULL) OR (production_department = ANY (ARRAY['arabic_sweets'::text, 'dragees'::text, 'fusion_sweets'::text, 'chocolates_confectionery'::text, 'seasoned_nuts_mixes'::text, 'bakery'::text])))
);

-- ---------------------------------------------------------------------------
-- Step 6: orders (depends on companies; self-referential
-- duplicate_of_order_id is safe within a single CREATE TABLE; closed_by and
-- finance_verified_by reference auth.users, which Supabase always provides)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  company_id uuid,
  status text NOT NULL DEFAULT 'submitted'::text,
  sales_order_value numeric DEFAULT 0,
  advance_required numeric DEFAULT 0,
  advance_paid numeric DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  payment_status text DEFAULT 'unpaid'::text,
  closed_at timestamptz,
  closed_by uuid,
  is_export boolean DEFAULT false,
  port_of_discharge text,
  country_of_origin text DEFAULT 'India'::text,
  document_stage text DEFAULT 'SO'::text,
  payment_cleared boolean DEFAULT false,
  eway_bill_number text,
  payment_receipt_url text,
  estimated_despatch_date date,
  actual_despatch_date date,
  tracking_number text,
  courier_name text,
  proforma_invoice_url text,
  final_invoice_url text,
  eway_bill_url text,
  requested_dispatch_date date,
  dispatch_urgency text DEFAULT 'standard'::text,
  admin_promised_date date,
  system_estimated_date date,
  gate_pass_number text,
  tracking_token text,
  is_starter_pack boolean NOT NULL DEFAULT false,
  total_weight_kg numeric,
  parser_confidence numeric,
  needs_clarification boolean NOT NULL DEFAULT false,
  is_waste boolean NOT NULL DEFAULT false,
  wamid text,
  is_duplicate boolean NOT NULL DEFAULT false,
  duplicate_of_order_id uuid,
  order_number text NOT NULL,
  finance_verified_by uuid,
  finance_verified_at timestamptz,
  payment_rejection_reason text,
  CONSTRAINT orders_pkey PRIMARY KEY (id),
  CONSTRAINT orders_order_number_key UNIQUE (order_number),
  CONSTRAINT orders_tracking_token_key UNIQUE (tracking_token),
  CONSTRAINT orders_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE,
  CONSTRAINT orders_duplicate_of_order_id_fkey FOREIGN KEY (duplicate_of_order_id) REFERENCES public.orders(id) ON DELETE SET NULL,
  CONSTRAINT orders_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES auth.users(id),
  CONSTRAINT orders_finance_verified_by_fkey FOREIGN KEY (finance_verified_by) REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ---------------------------------------------------------------------------
-- Step 7: order_items (depends on orders and products)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid,
  product_id uuid,
  quantity numeric NOT NULL DEFAULT 0,
  pack_size text,
  carton_type text,
  notes text,
  department text,
  production_status text DEFAULT 'pending'::text,
  task_type text DEFAULT 'customer'::text,
  actual_packed_qty integer,
  weight_kg numeric,
  CONSTRAINT order_items_pkey PRIMARY KEY (id),
  CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Step 8: indexes (non-constraint-backed indexes only -- PK/UNIQUE indexes
-- above are created automatically by their constraints)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_companies_is_frozen ON public.companies USING btree (is_frozen) WHERE (is_frozen = true);
CREATE INDEX IF NOT EXISTS idx_companies_phone ON public.companies USING btree (phone);

CREATE INDEX IF NOT EXISTS idx_users_email ON public.users USING btree (email);
CREATE INDEX IF NOT EXISTS idx_users_phone ON public.users USING btree (phone);
CREATE INDEX IF NOT EXISTS idx_users_secondary_phones ON public.users USING gin (secondary_phones);

CREATE INDEX IF NOT EXISTS idx_products_department ON public.products USING btree (department);

CREATE INDEX IF NOT EXISTS idx_orders_finance_verified_by ON public.orders USING btree (finance_verified_by);
CREATE INDEX IF NOT EXISTS idx_orders_is_waste ON public.orders USING btree (is_waste) WHERE (is_waste = false);
CREATE INDEX IF NOT EXISTS idx_orders_needs_clarification ON public.orders USING btree (needs_clarification) WHERE (needs_clarification = true);
CREATE INDEX IF NOT EXISTS idx_orders_payment_status_finance ON public.orders USING btree (payment_status, finance_verified_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS orders_is_duplicate_idx ON public.orders USING btree (is_duplicate) WHERE (is_duplicate = true);
CREATE UNIQUE INDEX IF NOT EXISTS orders_wamid_unique_idx ON public.orders USING btree (wamid) WHERE (wamid IS NOT NULL);
