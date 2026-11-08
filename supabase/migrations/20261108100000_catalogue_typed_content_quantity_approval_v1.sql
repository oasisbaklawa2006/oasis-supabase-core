-- Core #486: forward-only Product Master approved content quantity.
-- This contract accepts ONLY a reviewed typed packing.content_quantity object.
-- No inferred tray/carton, SKU-derived, piece-to-weight, MOQ or price conversion.
-- Missing typed content preserves historical legacy draft compatibility.
-- Existing product columns remain unchanged; approved updates preserve other
-- independently provided content facts (no automatic historical backfills).
--
-- Release lane: separate from Core #490 -> #491 -> #492 private-media train.
-- DO NOT APPLY TO PRODUCTION without protected review and complete replay.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.catalogue_parse_typed_content_quantity_v1(p_payload jsonb)
RETURNS TABLE (present boolean, pcs_per_pack numeric, net_weight_grams numeric)
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $quantity$
DECLARE
  v_content jsonb;
  v_unit text;
  v_value numeric;
BEGIN
  present := false;
  pcs_per_pack := NULL;
  net_weight_grams := NULL;
  v_content := p_payload #> '{packing,content_quantity}';

  IF v_content IS NULL THEN
    RETURN NEXT;
    RETURN;
  END IF;
  IF jsonb_typeof(v_content) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: expected object'
      USING ERRCODE = 'P0001';
  END IF;
  IF NOT (v_content ? 'unit' AND v_content ? 'value')
     OR (SELECT count(*) FROM jsonb_object_keys(v_content)) <> 2 THEN
    RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: expected {value, unit}'
      USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(v_content -> 'unit') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_content -> 'value') IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: unit string and numeric value required'
      USING ERRCODE = 'P0001';
  END IF;

  v_unit := v_content ->> 'unit';
  v_value := (v_content ->> 'value')::numeric;

  IF v_value IS NULL OR v_value <= 0 THEN
    RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: positive quantity required'
      USING ERRCODE = 'P0001';
  END IF;

  CASE v_unit
    WHEN 'pcs' THEN
      IF v_value <> trunc(v_value) OR v_value > 9007199254740991 THEN
        RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: pieces must be a safe positive integer'
          USING ERRCODE = 'P0001';
      END IF;
      pcs_per_pack := v_value;
    WHEN 'g' THEN
      net_weight_grams := v_value;
    WHEN 'kg' THEN
      -- Explicit SI conversion of approved kg to canonical net grams; no
      -- inference of products, tray counts, carton capacity or pieces.
      net_weight_grams := v_value * 1000;
    ELSE
      RAISE EXCEPTION 'INVALID_TYPED_CONTENT_QUANTITY: unsupported unit'
        USING ERRCODE = 'P0001';
  END CASE;

  present := true;
  RETURN NEXT;
END;
$quantity$;

-- This helper is internal to the reviewer-authorized SECURITY DEFINER
-- approval function. It is not intended as an anonymous Data API endpoint.
REVOKE ALL ON FUNCTION public.catalogue_parse_typed_content_quantity_v1(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.catalogue_parse_typed_content_quantity_v1(jsonb)
  TO service_role;

-- Reconstituted from the current Core main atomic approval definition with
-- only a typed pack-content validation and scoped products-column mapping.
-- No direct staff Product Master write or additional approval route.

CREATE OR REPLACE FUNCTION public.catalogue_approve_product_draft_atomic_v1(
  p_draft_table text,
  p_draft_id uuid,
  p_before jsonb,
  p_payload jsonb,
  p_operation text,
  p_target_record_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_after jsonb;
  v_product_id uuid;
  v_intake_barcode text;
  v_claimed_barcode text;
  v_pack_content record;
BEGIN
  IF NOT public.is_catalogue_reviewer() THEN
    RAISE EXCEPTION 'Catalogue reviewer permission required';
  END IF;

  IF p_draft_table <> 'catalogue_product_drafts' THEN
    RAISE EXCEPTION 'Unsupported draft table: %', p_draft_table;
  END IF;

  IF p_operation NOT IN ('create', 'update') THEN
    RAISE EXCEPTION 'Unsupported product draft operation: %', p_operation;
  END IF;

  IF p_operation = 'update' AND p_target_record_id IS NULL THEN
    RAISE EXCEPTION 'Product draft update requires target_record_id';
  END IF;

  -- Reviewer-approved typed content, never inferred from SKU, packaging or cartons.
  SELECT * INTO v_pack_content
    FROM public.catalogue_parse_typed_content_quantity_v1(p_payload);

  v_intake_barcode := public.catalogue_extract_reviewed_intake_barcode(p_payload);

  IF p_operation = 'create' THEN
    IF v_intake_barcode IS NOT NULL THEN
      v_claimed_barcode := public.catalogue_claim_intake_barcode(v_intake_barcode, NULL);
    END IF;

    INSERT INTO public.products (
      sku,
      name,
      category,
      sub_category,
      description,
      department,
      production_department,
      hsn_code,
      gst_rate,
      gst_percentage,
      mrp,
      price_b2b,
      price_bulk,
      price_wholesale,
      wholesale_price,
      uom,
      is_active,
      visible_in_catalog,
      pack_size,
      pcs_per_pack,
      net_weight_grams,
      ingredients,
      allergen_warnings,
      nutrition_facts,
      product_family,
      barcode_sku,
      created_at
    )
    VALUES (
      coalesce(
        nullif(p_payload #>> '{sku_draft,sku}', ''),
        'DRAFT-' || upper(substr(gen_random_uuid()::text, 1, 8))
      ),
      coalesce(p_payload #>> '{identity,product_name}', 'Unnamed Product'),
      coalesce(p_payload #>> '{identity,category}', 'Uncategorized'),
      p_payload #>> '{identity,subcategory}',
      coalesce(
        p_payload #>> '{identity,description}',
        p_payload #>> '{identity,short_description}'
      ),
      p_payload #>> '{identity,main_department}',
      nullif(p_payload #>> '{identity,production_department}', ''),
      p_payload #>> '{pricing,hsn}',
      nullif(p_payload #>> '{pricing,gst_rate}', '')::numeric,
      nullif(p_payload #>> '{pricing,gst_rate}', '')::numeric,
      nullif(p_payload #>> '{pricing,mrp}', '')::numeric,
      nullif(p_payload #>> '{pricing,b2b_price}', '')::numeric,
      nullif(p_payload #>> '{pricing,bulk_price}', '')::numeric,
      nullif(p_payload #>> '{pricing,wholesale_price}', '')::numeric,
      nullif(p_payload #>> '{pricing,wholesale_price}', '')::numeric,
      p_payload #>> '{uom,primary_uom}',
      true,
      false,
      coalesce(
        p_payload #>> '{packing,pack_preview}',
        p_payload #>> '{packing,primary_pack_type}'
      ),
      v_pack_content.pcs_per_pack,
      v_pack_content.net_weight_grams,
      p_payload #>> '{compliance,ingredients}',
      p_payload #>> '{compliance,allergen_information}',
      p_payload #>> '{compliance,nutritional_information}',
      coalesce(p_payload #>> '{identity,product_type}', 'General'),
      v_claimed_barcode,
      now()
    )
    RETURNING id INTO v_product_id;
  ELSIF p_operation = 'update' THEN
    IF v_intake_barcode IS NOT NULL THEN
      v_claimed_barcode := public.catalogue_claim_intake_barcode(v_intake_barcode, p_target_record_id);
    END IF;

    UPDATE public.products
    SET
      sku = coalesce(
        nullif(p_payload #>> '{sku_draft,sku}', ''),
        sku
      ),
      name = coalesce(p_payload #>> '{identity,product_name}', name),
      category = coalesce(p_payload #>> '{identity,category}', category),
      sub_category = coalesce(p_payload #>> '{identity,subcategory}', sub_category),
      description = coalesce(
        p_payload #>> '{identity,description}',
        p_payload #>> '{identity,short_description}',
        description
      ),
      department = coalesce(p_payload #>> '{identity,main_department}', department),
      production_department = coalesce(
        nullif(p_payload #>> '{identity,production_department}', ''),
        production_department
      ),
      hsn_code = coalesce(p_payload #>> '{pricing,hsn}', hsn_code),
      gst_rate = coalesce(nullif(p_payload #>> '{pricing,gst_rate}', '')::numeric, gst_rate),
      gst_percentage = coalesce(nullif(p_payload #>> '{pricing,gst_rate}', '')::numeric, gst_percentage),
      mrp = coalesce(nullif(p_payload #>> '{pricing,mrp}', '')::numeric, mrp),
      price_b2b = coalesce(nullif(p_payload #>> '{pricing,b2b_price}', '')::numeric, price_b2b),
      price_bulk = coalesce(nullif(p_payload #>> '{pricing,bulk_price}', '')::numeric, price_bulk),
      price_wholesale = coalesce(nullif(p_payload #>> '{pricing,wholesale_price}', '')::numeric, price_wholesale),
      wholesale_price = coalesce(nullif(p_payload #>> '{pricing,wholesale_price}', '')::numeric, wholesale_price),
      uom = coalesce(p_payload #>> '{uom,primary_uom}', uom),
      pack_size = coalesce(
        p_payload #>> '{packing,pack_preview}',
        p_payload #>> '{packing,primary_pack_type}',
        pack_size
      ),
      pcs_per_pack = coalesce(v_pack_content.pcs_per_pack, pcs_per_pack),
      net_weight_grams = coalesce(v_pack_content.net_weight_grams, net_weight_grams),
      ingredients = coalesce(p_payload #>> '{compliance,ingredients}', ingredients),
      allergen_warnings = coalesce(p_payload #>> '{compliance,allergen_information}', allergen_warnings),
      nutrition_facts = coalesce(p_payload #>> '{compliance,nutritional_information}', nutrition_facts),
      product_family = coalesce(p_payload #>> '{identity,product_type}', product_family),
      barcode_sku = coalesce(v_claimed_barcode, barcode_sku)
    WHERE id = p_target_record_id
    RETURNING id INTO v_product_id;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Target product not found: %', p_target_record_id;
    END IF;
  END IF;

  EXECUTE format(
    'UPDATE public.%I
        SET status = ''approved'',
            target_record_id = $2,
            reviewed_by = auth.uid(),
            reviewed_at = now(),
            review_notes = ''Approved and mapped to public.products'',
            updated_at = now()
      WHERE id = $1',
    p_draft_table
  )
  USING p_draft_id, v_product_id;

  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE id = $1', p_draft_table)
    USING p_draft_id
    INTO v_after;

  INSERT INTO public.catalogue_approval_audit (
    draft_table,
    draft_id,
    action,
    performed_by,
    payload_snapshot,
    before_snapshot,
    after_snapshot,
    notes
  )
  VALUES (
    p_draft_table,
    p_draft_id,
    'approved',
    auth.uid(),
    p_payload,
    p_before,
    v_after,
    CASE
      WHEN v_claimed_barcode IS NOT NULL THEN
        'Product draft approved with atomic intake_barcode association'
      ELSE
        'Product draft approved and mapped to public.products'
    END
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'approved',
    'draft_table', p_draft_table,
    'draft_id', p_draft_id,
    'target_record_id', v_product_id,
    'intake_barcode', v_claimed_barcode
  );
END;
$$;

COMMENT ON FUNCTION public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid) IS
  'Governed atomic catalogue approval: retains barcode claims and writes validated, explicitly reviewed pcs_per_pack or net_weight_grams, without inferred packing or commercial authority.';
