
-- Roles
CREATE TYPE public.app_role AS ENUM ('owner','admin','product_manager','catalogue_manager','designer','sales');

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  full_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role app_role NOT NULL,
  UNIQUE(user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role);
$$;

CREATE OR REPLACE FUNCTION public.is_team_member(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id);
$$;

-- Auto-create profile + first user becomes owner
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  user_count int;
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email));
  SELECT COUNT(*) INTO user_count FROM public.profiles;
  IF user_count = 1 THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'owner');
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'sales');
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- updated_at helper
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- Products
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku TEXT UNIQUE NOT NULL,
  product_name TEXT NOT NULL,
  short_name TEXT,
  category TEXT,
  subcategory TEXT,
  product_type TEXT,
  description TEXT,
  short_description TEXT,
  pack_size TEXT,
  net_weight_g NUMERIC,
  gross_weight_g NUMERIC,
  shelf_life_days INTEGER,
  storage_instructions TEXT,
  hsn_code TEXT,
  gst_rate NUMERIC,
  mrp NUMERIC,
  b2b_price NUMERIC,
  export_price NUMERIC,
  currency TEXT DEFAULT 'INR',
  moq_text TEXT,
  carton_logic TEXT,
  hero_image_url TEXT,
  is_active BOOLEAN DEFAULT true,
  is_catalogue_ready BOOLEAN DEFAULT false,
  label_status TEXT DEFAULT 'draft',
  media_status TEXT DEFAULT 'missing',
  is_sample BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER products_touch BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Media
CREATE TABLE public.product_media (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
  file_url TEXT NOT NULL,
  type TEXT,
  status TEXT DEFAULT 'raw',
  angle TEXT,
  alt_text TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.product_media ENABLE ROW LEVEL SECURITY;

-- Tags
CREATE TABLE public.tags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  group_name TEXT NOT NULL,
  UNIQUE(name, group_name)
);
ALTER TABLE public.tags ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.product_tags (
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
  tag_id UUID REFERENCES public.tags(id) ON DELETE CASCADE,
  PRIMARY KEY (product_id, tag_id)
);
ALTER TABLE public.product_tags ENABLE ROW LEVEL SECURITY;

-- Catalogues
CREATE TABLE public.catalogues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  subtitle TEXT,
  client_name TEXT,
  catalogue_type TEXT DEFAULT 'general',
  theme TEXT DEFAULT 'classic_white',
  price_visibility TEXT DEFAULT 'hidden',
  language TEXT DEFAULT 'en',
  cover_image_url TEXT,
  intro_text TEXT,
  expiry_date DATE,
  public_slug TEXT UNIQUE,
  is_published BOOLEAN DEFAULT false,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.catalogues ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER catalogues_touch BEFORE UPDATE ON public.catalogues FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.catalogue_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  catalogue_id UUID NOT NULL REFERENCES public.catalogues(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  sort_order INTEGER DEFAULT 0,
  section TEXT,
  UNIQUE(catalogue_id, product_id)
);
ALTER TABLE public.catalogue_products ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.share_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  catalogue_id UUID REFERENCES public.catalogues(id) ON DELETE CASCADE,
  slug TEXT UNIQUE NOT NULL,
  recipient TEXT,
  channel TEXT DEFAULT 'whatsapp',
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.share_links ENABLE ROW LEVEL SECURITY;

-- Hampers
CREATE TABLE public.hampers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  estimated_weight_g NUMERIC,
  estimated_cost NUMERIC,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.hampers ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER hampers_touch BEFORE UPDATE ON public.hampers FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.hamper_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  hamper_id UUID NOT NULL REFERENCES public.hampers(id) ON DELETE CASCADE,
  child_product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  component_name TEXT,
  quantity NUMERIC DEFAULT 1,
  unit TEXT DEFAULT 'pc',
  is_customer_visible BOOLEAN DEFAULT true,
  is_packaging_component BOOLEAN DEFAULT false
);
ALTER TABLE public.hamper_items ENABLE ROW LEVEL SECURITY;

-- Ingredients & nutrition
CREATE TABLE public.ingredients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  allergen_group TEXT,
  veg_status TEXT DEFAULT 'veg',
  notes TEXT
);
ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.product_ingredients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  ingredient_id UUID NOT NULL REFERENCES public.ingredients(id) ON DELETE CASCADE,
  percentage NUMERIC,
  display_order INTEGER DEFAULT 0
);
ALTER TABLE public.product_ingredients ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.nutrition_panels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID UNIQUE NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  serving_size TEXT,
  energy_kcal NUMERIC,
  protein_g NUMERIC,
  carbohydrate_g NUMERIC,
  total_sugar_g NUMERIC,
  added_sugar_g NUMERIC,
  total_fat_g NUMERIC,
  saturated_fat_g NUMERIC,
  trans_fat_g NUMERIC,
  sodium_mg NUMERIC,
  remarks TEXT,
  needs_review BOOLEAN DEFAULT true
);
ALTER TABLE public.nutrition_panels ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.labels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID UNIQUE NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  net_quantity TEXT,
  mrp NUMERIC,
  batch_no TEXT,
  mfg_date DATE,
  best_before TEXT,
  fssai_license TEXT,
  manufacturer TEXT,
  customer_care TEXT,
  barcode TEXT,
  country_of_origin TEXT DEFAULT 'India',
  status TEXT DEFAULT 'draft',
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.labels ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER labels_touch BEFORE UPDATE ON public.labels FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.ai_generation_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
  job_type TEXT,
  status TEXT DEFAULT 'planned',
  input JSONB,
  output JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.ai_generation_jobs ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.integration_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT UNIQUE NOT NULL,
  label TEXT,
  status TEXT DEFAULT 'not_connected',
  notes TEXT
);
ALTER TABLE public.integration_settings ENABLE ROW LEVEL SECURITY;

-- ============= RLS POLICIES =============
-- Profiles
CREATE POLICY "Profiles viewable by team" ON public.profiles FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Users update own profile" ON public.profiles FOR UPDATE TO authenticated USING (id = auth.uid());

-- User roles
CREATE POLICY "Roles viewable by team" ON public.user_roles FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Owners manage roles" ON public.user_roles FOR ALL TO authenticated USING (public.has_role(auth.uid(),'owner')) WITH CHECK (public.has_role(auth.uid(),'owner'));

-- Generic team-managed tables
CREATE POLICY "Public read products" ON public.products FOR SELECT USING (true);
CREATE POLICY "Team write products" ON public.products FOR INSERT TO authenticated WITH CHECK (public.is_team_member(auth.uid()));
CREATE POLICY "Team update products" ON public.products FOR UPDATE TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team delete products" ON public.products FOR DELETE TO authenticated USING (public.is_team_member(auth.uid()));

CREATE POLICY "Public read media" ON public.product_media FOR SELECT USING (true);
CREATE POLICY "Team write media" ON public.product_media FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Public read tags" ON public.tags FOR SELECT USING (true);
CREATE POLICY "Team write tags" ON public.tags FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Public read product_tags" ON public.product_tags FOR SELECT USING (true);
CREATE POLICY "Team write product_tags" ON public.product_tags FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Public read published catalogues" ON public.catalogues FOR SELECT USING (is_published = true OR public.is_team_member(auth.uid()));
CREATE POLICY "Team write catalogues" ON public.catalogues FOR INSERT TO authenticated WITH CHECK (public.is_team_member(auth.uid()));
CREATE POLICY "Team update catalogues" ON public.catalogues FOR UPDATE TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team delete catalogues" ON public.catalogues FOR DELETE TO authenticated USING (public.is_team_member(auth.uid()));

CREATE POLICY "Public read catalogue_products" ON public.catalogue_products FOR SELECT USING (true);
CREATE POLICY "Team write catalogue_products" ON public.catalogue_products FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Public read share_links" ON public.share_links FOR SELECT USING (true);
CREATE POLICY "Team write share_links" ON public.share_links FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read hampers" ON public.hampers FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write hampers" ON public.hampers FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read hamper_items" ON public.hamper_items FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write hamper_items" ON public.hamper_items FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read ingredients" ON public.ingredients FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write ingredients" ON public.ingredients FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read product_ingredients" ON public.product_ingredients FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write product_ingredients" ON public.product_ingredients FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read nutrition" ON public.nutrition_panels FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write nutrition" ON public.nutrition_panels FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read labels" ON public.labels FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write labels" ON public.labels FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read ai_jobs" ON public.ai_generation_jobs FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Team write ai_jobs" ON public.ai_generation_jobs FOR ALL TO authenticated USING (public.is_team_member(auth.uid())) WITH CHECK (public.is_team_member(auth.uid()));

CREATE POLICY "Team read integrations" ON public.integration_settings FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
CREATE POLICY "Owner write integrations" ON public.integration_settings FOR ALL TO authenticated USING (public.has_role(auth.uid(),'owner')) WITH CHECK (public.has_role(auth.uid(),'owner'));
