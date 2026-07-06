
-- Extend products
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS sku_locked boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS sku_generated_at timestamptz,
  ADD COLUMN IF NOT EXISTS sku_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS division_code text,
  ADD COLUMN IF NOT EXISTS category_code text,
  ADD COLUMN IF NOT EXISTS subcategory_code text,
  ADD COLUMN IF NOT EXISTS packaging_code text,
  ADD COLUMN IF NOT EXISTS serial_no integer,
  ADD COLUMN IF NOT EXISTS legacy_sku text,
  ADD COLUMN IF NOT EXISTS external_reference_code text;

-- Ensure SKU uniqueness
DO $$ BEGIN
  ALTER TABLE public.products ADD CONSTRAINT products_sku_unique UNIQUE (sku);
EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL; END $$;

-- pg_trgm for fuzzy
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- SKU code rules
CREATE TABLE IF NOT EXISTS public.sku_code_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code_type text NOT NULL CHECK (code_type IN ('division','category','subcategory','packaging')),
  code text NOT NULL,
  label text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(code_type, code)
);
ALTER TABLE public.sku_code_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read sku rules" ON public.sku_code_rules FOR SELECT USING (true);
CREATE POLICY "Team write sku rules" ON public.sku_code_rules FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

-- SKU sequences
CREATE TABLE IF NOT EXISTS public.sku_sequences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  division_code text NOT NULL,
  category_code text NOT NULL,
  subcategory_code text NOT NULL,
  packaging_code text NOT NULL,
  last_serial integer NOT NULL DEFAULT 0,
  UNIQUE(division_code, category_code, subcategory_code, packaging_code)
);
ALTER TABLE public.sku_sequences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Team read sequences" ON public.sku_sequences FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write sequences" ON public.sku_sequences FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

-- Normalize alias
CREATE OR REPLACE FUNCTION public.normalize_alias(_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(lower(trim(coalesce(_text,''))), '\s+', ' ', 'g');
$$;

-- Product aliases
CREATE TABLE IF NOT EXISTS public.product_aliases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  alias text NOT NULL CHECK (length(trim(alias)) > 0),
  normalized_alias text GENERATED ALWAYS AS (public.normalize_alias(alias)) STORED,
  language text,
  script text,
  alias_type text NOT NULL DEFAULT 'common_name',
  source text NOT NULL DEFAULT 'manual',
  confidence_score numeric NOT NULL DEFAULT 1.0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  UNIQUE(product_id, normalized_alias)
);
CREATE INDEX IF NOT EXISTS idx_product_aliases_norm_trgm ON public.product_aliases USING gin (normalized_alias gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON public.products USING gin (lower(product_name) gin_trgm_ops);

ALTER TABLE public.product_aliases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read aliases" ON public.product_aliases FOR SELECT USING (true);
CREATE POLICY "Team write aliases" ON public.product_aliases FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

-- SKU generator
CREATE OR REPLACE FUNCTION public.generate_oasis_sku(
  _division_code text, _category_code text, _subcategory_code text, _packaging_code text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_serial integer;
  v_sku text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sku_code_rules WHERE code_type='division' AND code=_division_code AND is_active) THEN
    RAISE EXCEPTION 'Invalid division code: %', _division_code; END IF;
  IF NOT EXISTS (SELECT 1 FROM sku_code_rules WHERE code_type='category' AND code=_category_code AND is_active) THEN
    RAISE EXCEPTION 'Invalid category code: %', _category_code; END IF;
  IF NOT EXISTS (SELECT 1 FROM sku_code_rules WHERE code_type='subcategory' AND code=_subcategory_code AND is_active) THEN
    RAISE EXCEPTION 'Invalid subcategory code: %', _subcategory_code; END IF;
  IF NOT EXISTS (SELECT 1 FROM sku_code_rules WHERE code_type='packaging' AND code=_packaging_code AND is_active) THEN
    RAISE EXCEPTION 'Invalid packaging code: %', _packaging_code; END IF;

  INSERT INTO sku_sequences (division_code, category_code, subcategory_code, packaging_code, last_serial)
  VALUES (_division_code, _category_code, _subcategory_code, _packaging_code, 1)
  ON CONFLICT (division_code, category_code, subcategory_code, packaging_code)
  DO UPDATE SET last_serial = sku_sequences.last_serial + 1
  RETURNING last_serial INTO v_serial;

  v_sku := 'OAS-' || _division_code || '-' || _category_code || '-' || _subcategory_code || '-' || _packaging_code || '-' || lpad(v_serial::text, 4, '0');
  RETURN v_sku;
END; $$;

-- Search with aliases
CREATE OR REPLACE FUNCTION public.search_products_with_aliases(_q text)
RETURNS TABLE (
  id uuid, sku text, product_name text, short_name text, category text,
  hero_image_url text, matched_alias text, match_score real
) LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT public.normalize_alias(_q) AS nq)
  SELECT p.id, p.sku, p.product_name, p.short_name, p.category, p.hero_image_url,
         NULL::text AS matched_alias,
         GREATEST(
           similarity(lower(p.product_name), (SELECT nq FROM q)),
           CASE WHEN lower(p.sku) LIKE '%'||(SELECT nq FROM q)||'%' THEN 1.0 ELSE 0 END,
           CASE WHEN lower(p.product_name) LIKE '%'||(SELECT nq FROM q)||'%' THEN 0.9 ELSE 0 END
         )::real AS match_score
  FROM public.products p, q
  WHERE lower(p.product_name) LIKE '%'||q.nq||'%'
     OR lower(p.sku) LIKE '%'||q.nq||'%'
     OR lower(coalesce(p.short_name,'')) LIKE '%'||q.nq||'%'
     OR similarity(lower(p.product_name), q.nq) > 0.3
  UNION
  SELECT p.id, p.sku, p.product_name, p.short_name, p.category, p.hero_image_url,
         a.alias AS matched_alias,
         GREATEST(
           similarity(a.normalized_alias, (SELECT nq FROM q)),
           CASE WHEN a.normalized_alias LIKE '%'||(SELECT nq FROM q)||'%' THEN 0.95 ELSE 0 END
         )::real AS match_score
  FROM public.product_aliases a
  JOIN public.products p ON p.id = a.product_id, q
  WHERE a.is_active
    AND (a.normalized_alias LIKE '%'||q.nq||'%' OR similarity(a.normalized_alias, q.nq) > 0.3)
  ORDER BY match_score DESC NULLS LAST
  LIMIT 50;
$$;

-- Seed code rules
INSERT INTO public.sku_code_rules (code_type, code, label, sort_order) VALUES
  ('division','AS','Arabic Sweets',10),
  ('division','CH','Chocolate & Confectionery',20),
  ('division','BK','Bakery',30),
  ('division','FS','Fusion Sweets',40),
  ('division','SN','Seasoned Nuts & Mixes',50),
  ('division','GF','Gifting',60),
  ('division','PK','Packaging Material',70),
  ('division','FR','Frozen / Semi Prepared',80),
  ('category','BKL','Baklawa',10),
  ('category','KNF','Kunafa / Kadayif',20),
  ('category','DAT','Dates',30),
  ('category','DRG','Dragees',40),
  ('category','NUT','Nuts',50),
  ('category','CKE','Cakes',60),
  ('category','HMP','Hampers',70),
  ('category','BOX','Boxes',80),
  ('category','JAR','Jars',90),
  ('category','RAW','Raw Material',100),
  ('subcategory','PYR','Pyramid',10),
  ('subcategory','ROL','Rolls',20),
  ('subcategory','BIR','Bird Nest',30),
  ('subcategory','KAT','Katori / Tart',40),
  ('subcategory','SQR','Square',50),
  ('subcategory','ASS','Assorted',60),
  ('subcategory','PST','Pistachio',70),
  ('subcategory','CSH','Cashew',80),
  ('subcategory','ALM','Almond',90),
  ('subcategory','MIX','Mixed',100),
  ('subcategory','EID','Eid',110),
  ('subcategory','DWL','Diwali',120),
  ('subcategory','WED','Wedding',130),
  ('subcategory','KNF','Kunafa',140),
  ('subcategory','KDF','Kadayif',150),
  ('subcategory','KTF','Kataifi',160),
  ('packaging','MAAPET','PET Tray',10),
  ('packaging','666','PET Box 666',20),
  ('packaging','888','PET Box 888',30),
  ('packaging','JAR500','500g Jar',40),
  ('packaging','TRAY1KG','1kg Tray',50),
  ('packaging','RBOX','Rigid Box',60),
  ('packaging','TIN','Tin Box',70),
  ('packaging','FROZEN','Frozen Pack',80),
  ('packaging','LOOSE','Loose',90),
  ('packaging','BULK','Bulk Pack',100)
ON CONFLICT (code_type, code) DO NOTHING;

-- Migrate existing products: preserve old SKU as legacy_sku, assign system SKU
DO $$
DECLARE
  r record;
  new_sku text;
BEGIN
  FOR r IN SELECT id, sku FROM public.products WHERE sku IS NOT NULL AND (sku NOT LIKE 'OAS-%' OR division_code IS NULL) LOOP
    UPDATE public.products SET legacy_sku = r.sku WHERE id = r.id AND legacy_sku IS NULL;
    new_sku := public.generate_oasis_sku('AS','BKL','ASS','LOOSE');
    UPDATE public.products
      SET sku = new_sku,
          division_code='AS', category_code='BKL', subcategory_code='ASS', packaging_code='LOOSE',
          serial_no = CAST(right(new_sku,4) AS integer),
          sku_generated_at = now(), sku_locked = true
      WHERE id = r.id;
  END LOOP;
END $$;
