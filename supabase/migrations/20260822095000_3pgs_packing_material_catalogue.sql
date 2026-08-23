-- Central issue #368 operational-closure programme, Phase 4A (3PGS insider
-- packing-material catalogue). Read-only. No new authority, no new RPC, no
-- role change -- booking itself reuses the existing reserve_rgs_stock RPC
-- (20260817100000_rgs_production_governed_authority.sql), gated for
-- authorised insiders via is_inventory_manage_role/is_inventory_receive_role,
-- exactly as it already is for every other RGS demand source.
--
-- Owner-directed scope correction: this catalogue is NOT every item 3PGS
-- holds. It is specifically packing/assembly consumables (boxes, trays,
-- sleeves, jars, tins, ribbons where governed as packing stock, outer
-- cartons, pouches, inventory-controlled labels/packaging components,
-- imported/Indian packaging material, other packing/assembly consumables)
-- that authorised managers/staff need to browse and book. Bought-out/
-- third-party finished goods 3PGS may also hold operationally
-- (item_class = 'sourced_ready_product') are deliberately excluded from
-- this view -- they do not belong in the manager-facing booking catalogue
-- unless separately reclassified as bookable packing material.
--
-- Eligibility is driven entirely by the existing canonical classification on
-- b2b_inventory_item_profiles (item_class = 'packaging_material',
-- primary_store_code = '3PGS'), introduced in
-- 20260803194132_phase2_b2b_store_fulfilment_contract.sql. No new
-- classification column or migration is needed -- the model already
-- distinguishes exactly what this catalogue needs.
--
-- Out-of-stock packing material remains visible (per owner directive: it
-- must not disappear from the catalogue) with the earliest open
-- procurement requirement's expected_at as its lead time, if one exists.

CREATE OR REPLACE VIEW public.b2b_3pgs_packing_material_catalogue
WITH (security_invoker = true)
AS
SELECT
  profile.product_id,
  profile.sku,
  coalesce(nullif(btrim(product.product_name), ''), product.name) AS product_name,
  nullif(btrim(product.short_description), '') AS description,
  coalesce(nullif(btrim(product.hero_image_url), ''), nullif(btrim(product.image_url), '')) AS image_url,
  product.pack_size,
  coalesce(nullif(btrim(product.primary_uom), ''), nullif(btrim(product.uom), '')) AS uom,
  coalesce(balance.available_qty, 0::numeric) AS available_qty,
  coalesce(balance.reserved_qty, 0::numeric) AS reserved_qty,
  CASE WHEN coalesce(balance.available_qty, 0::numeric) > 0 THEN 'available' ELSE 'unavailable' END AS availability_status,
  lead_time.earliest_expected_at AS lead_time_expected_at,
  profile.updated_at
FROM public.b2b_inventory_item_profiles profile
JOIN public.products product
  ON product.id = profile.product_id
LEFT JOIN public.inventory_stock_balances balance
  ON balance.product_id = profile.product_id
 AND balance.sku = profile.sku
 AND balance.location_code = '3PGS'
LEFT JOIN LATERAL (
  SELECT min(requirement.expected_at) AS earliest_expected_at
  FROM public.b2b_procurement_requirements requirement
  WHERE requirement.product_id = profile.product_id
    AND requirement.sku = profile.sku
    AND requirement.destination_store_code = '3PGS'
    AND requirement.status NOT IN ('received', 'cancelled')
    AND requirement.expected_at IS NOT NULL
) lead_time ON true
WHERE profile.primary_store_code = '3PGS'
  AND profile.item_class = 'packaging_material'
  AND profile.b2b_relevant;

COMMENT ON VIEW public.b2b_3pgs_packing_material_catalogue IS
  'Central issue #368 Phase 4A: insider-facing 3PGS packing-material catalogue. Scoped strictly to item_class = packaging_material at the 3PGS store -- excludes sourced_ready_product (bought-out finished goods) by design. Out-of-stock items remain visible with lead_time_expected_at from the earliest open procurement requirement, if any. Booking reuses reserve_rgs_stock; this view is read-only.';
