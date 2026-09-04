-- Point 29 blocker closure: preview reconciliation for branches that applied
-- 20260904030100 before security/routing/idempotency hardening. Fresh replays
-- are idempotent via CREATE OR REPLACE in both migrations.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

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
  'Atomic catalogue product-draft approval. Persists reviewed intake_barcode on products.barcode_sku in the same transaction as product create/update.';

CREATE OR REPLACE FUNCTION public.submit_catalogue_product_draft_v1(
  p_operation text,
  p_target_record_id uuid,
  p_payload jsonb
)
RETURNS TABLE(draft_id uuid, already_pending boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_sku text := nullif(btrim(p_payload #>> '{sku_draft,sku}'), '');
  v_intake_barcode text;
  v_id uuid;
  v_conflict_submitter uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.has_catalogue_permission('catalogue.products.submit') THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED' USING ERRCODE = 'P0001';
  END IF;

  IF p_operation NOT IN ('create', 'update', 'delete_request') THEN
    RAISE EXCEPTION 'INVALID_PRODUCT_DRAFT_OPERATION' USING ERRCODE = 'P0001';
  END IF;

  IF p_operation = 'update' AND p_target_record_id IS NULL THEN
    RAISE EXCEPTION 'PRODUCT_DRAFT_UPDATE_REQUIRES_TARGET' USING ERRCODE = 'P0001';
  END IF;

  v_intake_barcode := public.catalogue_extract_reviewed_intake_barcode(p_payload);
  IF v_intake_barcode IS NOT NULL THEN
    PERFORM public.catalogue_validate_intake_barcode(v_intake_barcode);
  END IF;

  IF v_sku IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('catalogue_product_draft:' || lower(v_sku), 0));

    SELECT d.id
      INTO v_id
      FROM public.catalogue_product_drafts d
     WHERE d.status = 'pending_approval'
       AND d.submitted_by = v_user
       AND d.operation = p_operation
       AND d.target_record_id IS NOT DISTINCT FROM p_target_record_id
       AND lower(coalesce(d.payload #>> '{sku_draft,sku}', '')) = lower(v_sku)
     ORDER BY d.created_at, d.id
     LIMIT 1;

    IF v_id IS NOT NULL THEN
      RETURN QUERY SELECT v_id, true;
      RETURN;
    END IF;

    SELECT d.submitted_by
      INTO v_conflict_submitter
      FROM public.catalogue_product_drafts d
     WHERE d.status = 'pending_approval'
       AND lower(coalesce(d.payload #>> '{sku_draft,sku}', '')) = lower(v_sku)
       AND d.submitted_by IS DISTINCT FROM v_user
     ORDER BY d.created_at, d.id
     LIMIT 1;

    IF v_conflict_submitter IS NOT NULL THEN
      RAISE EXCEPTION 'CATALOGUE_PRODUCT_DRAFT_SKU_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  INSERT INTO public.catalogue_product_drafts (
    source_app,
    target_table,
    target_record_id,
    operation,
    payload,
    status,
    submitted_by,
    submitted_at,
    created_at,
    updated_at
  )
  VALUES (
    'catalogue_app',
    'products',
    p_target_record_id,
    p_operation,
    p_payload,
    'pending_approval',
    v_user,
    now(),
    now(),
    now()
  )
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, false;
END;
$$;

COMMENT ON FUNCTION public.submit_catalogue_product_draft_v1(text, uuid, jsonb) IS
  'Governed contributor product-draft submit with intake_barcode payload preservation and SKU-scoped idempotency.';
REVOKE ALL ON FUNCTION public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_catalogue_product_draft_v1(text, uuid, jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.catalogue_extract_reviewed_intake_barcode(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_validate_intake_barcode(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_claim_intake_barcode(text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_catalogue_product_draft_v1(text, uuid, jsonb) TO authenticated, service_role;
