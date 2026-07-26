
CREATE OR REPLACE FUNCTION public.normalize_alias(_text text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT regexp_replace(lower(trim(coalesce(_text,''))), '\s+', ' ', 'g');
$$;

CREATE OR REPLACE FUNCTION public.search_products_with_aliases(_q text)
RETURNS TABLE (
  id uuid, sku text, product_name text, short_name text, category text,
  hero_image_url text, matched_alias text, match_score real
) LANGUAGE sql STABLE SET search_path = public AS $$
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
