-- Point 29 (AI Studio #135 / Core #179): atomic reviewed intake-barcode persistence
-- with catalogue product draft approval. Product master writes and barcode_sku
-- association must commit or roll back together inside Core authority.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.catalogue_extract_reviewed_intake_barcode(p_payload jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT nullif(btrim(coalesce(
    p_payload #>> '{intake_barcode}',
    p_payload #>> '{sku_draft,intake_barcode}',
    p_payload #>> '{labeling,intake_barcode}',
    p_payload #>> '{labelling,intake_barcode}',
    p_payload #>> '{barcode,intake_barcode}'
  )), '');
$$;

COMMENT ON FUNCTION public.catalogue_extract_reviewed_intake_barcode(jsonb) IS
  'Extracts the reviewed intake barcode from governed catalogue product-draft payloads.';

CREATE OR REPLACE FUNCTION public.catalogue_validate_intake_barcode(p_barcode text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_barcode text := nullif(btrim(p_barcode), '');
BEGIN
  IF v_barcode IS NULL THEN
    RAISE EXCEPTION 'CATALOGUE_INTAKE_BARCODE_REQUIRED' USING ERRCODE = '22023';
  END IF;

  IF length(v_barcode) < 4 OR length(v_barcode) > 64 THEN
    RAISE EXCEPTION 'CATALOGUE_INTAKE_BARCODE_INVALID' USING ERRCODE = '22023';
  END IF;

  IF v_barcode !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]*$' THEN
    RAISE EXCEPTION 'CATALOGUE_INTAKE_BARCODE_INVALID' USING ERRCODE = '22023';
  END IF;

  RETURN v_barcode;
END;
$$;

COMMENT ON FUNCTION public.catalogue_validate_intake_barcode(text) IS
  'Fail-closed intake barcode format validation for catalogue product authority.';

CREATE OR REPLACE FUNCTION public.catalogue_claim_intake_barcode(
  p_barcode text,
  p_exclude_product_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_barcode text;
  v_conflict uuid;
BEGIN
  v_barcode := public.catalogue_validate_intake_barcode(p_barcode);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('catalogue_intake_barcode:' || lower(v_barcode), 0)
  );

  SELECT p.id
    INTO v_conflict
    FROM public.products p
   WHERE p.id IS DISTINCT FROM p_exclude_product_id
     AND (
       lower(btrim(coalesce(p.barcode_sku, ''))) = lower(v_barcode)
       OR lower(btrim(coalesce(p.sku, ''))) = lower(v_barcode)
     )
   LIMIT 1;

  IF v_conflict IS NOT NULL THEN
    RAISE EXCEPTION 'CATALOGUE_INTAKE_BARCODE_DUPLICATE' USING ERRCODE = '23505';
  END IF;

  RETURN v_barcode;
END;
$$;

COMMENT ON FUNCTION public.catalogue_claim_intake_barcode(text, uuid) IS
  'Serializes intake-barcode claims and rejects duplicates against products.barcode_sku and products.sku.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_intake_barcode_normalized_unique
  ON public.products (lower(btrim(barcode_sku)))
  WHERE barcode_sku IS NOT NULL AND btrim(barcode_sku) <> '';

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

CREATE OR REPLACE FUNCTION public.approve_catalogue_draft_internal(
  p_draft_table text,
  p_draft_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $_$
DECLARE
  v_before jsonb;
  v_after jsonb;
  v_status text;
  v_payload jsonb;
  v_operation text;
  v_target_record_id uuid;
  v_product_id uuid;
  v_tag_id uuid;
  v_tag_key text;
  v_tag_label text;
  v_group_slug text;
  v_alias_id uuid;
  v_alias_text text;
  v_canonical_name text;
  v_master_before jsonb;
  v_allowed text[] := ARRAY[
    'catalogue_product_drafts',
    'catalogue_media_submissions',
    'catalogue_alias_drafts',
    'catalogue_bom_drafts',
    'catalogue_moq_drafts',
    'catalogue_pricing_drafts',
    'catalogue_tag_drafts'
  ];
BEGIN
  IF NOT public.is_catalogue_reviewer() THEN
    RAISE EXCEPTION 'Catalogue reviewer permission required';
  END IF;

  IF NOT (p_draft_table = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'Unsupported draft table: %', p_draft_table;
  END IF;

  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE id = $1 FOR UPDATE', p_draft_table)
    USING p_draft_id
    INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Draft not found: %.%', p_draft_table, p_draft_id;
  END IF;

  v_status := v_before ->> 'status';

  IF v_status <> 'pending_approval' THEN
    RAISE EXCEPTION 'Only pending_approval drafts can be approved. Current status: %', v_status;
  END IF;

  v_payload := v_before -> 'payload';
  v_operation := coalesce(v_before ->> 'operation', 'create');

  IF nullif(v_before ->> 'target_record_id', '') IS NOT NULL THEN
    v_target_record_id := (v_before ->> 'target_record_id')::uuid;
  END IF;

  IF p_draft_table = 'catalogue_product_drafts' THEN
    RETURN public.catalogue_approve_product_draft_atomic_v1(
      p_draft_table,
      p_draft_id,
      v_before,
      v_payload,
      v_operation,
      v_target_record_id
    );
  END IF;

  IF p_draft_table = 'catalogue_tag_drafts' THEN
    IF coalesce(v_payload ->> 'scope', '') <> 'tag_vocabulary' THEN
      RAISE EXCEPTION 'Unexpected payload scope "%", expected "tag_vocabulary"', coalesce(v_payload ->> 'scope', '');
    END IF;

    IF v_operation = 'update' THEN
      RAISE EXCEPTION 'Tag vocabulary update is not supported; reject or submit create/delete_request';
    END IF;

    IF v_operation NOT IN ('create', 'delete_request') THEN
      RAISE EXCEPTION 'Unsupported tag draft operation: %', v_operation;
    END IF;

    v_tag_label := nullif(btrim(coalesce(v_payload ->> 'tag_label', v_payload ->> 'name')), '');
    IF v_tag_label IS NULL THEN
      RAISE EXCEPTION 'Tag draft requires name or tag_label in payload';
    END IF;

    v_group_slug := public.catalogue_slugify_tag_part(coalesce(v_payload ->> 'group_name', 'general'));
    v_tag_key := nullif(btrim(v_payload ->> 'tag_key'), '');
    IF v_tag_key IS NULL THEN
      v_tag_key := v_group_slug || ':' || public.catalogue_slugify_tag_part(v_tag_label);
    END IF;

    IF v_operation = 'create' THEN
      BEGIN
        INSERT INTO public.product_tags (tag_key, tag_label, is_active, sort_order)
        VALUES (
          v_tag_key,
          v_tag_label,
          coalesce((v_payload ->> 'is_active')::boolean, true),
          coalesce((v_payload ->> 'sort_order')::integer, 0)
        )
        RETURNING id INTO v_tag_id;
      EXCEPTION
        WHEN unique_violation THEN
          SELECT pt.id
          INTO v_tag_id
          FROM public.product_tags pt
          WHERE pt.tag_key = v_tag_key;

          IF v_tag_id IS NULL THEN
            RAISE EXCEPTION 'Tag key conflict but existing row not found: %', v_tag_key;
          END IF;
      END;

      v_target_record_id := v_tag_id;
    ELSE
      IF v_target_record_id IS NULL THEN
        RAISE EXCEPTION 'Tag delete_request requires target_record_id';
      END IF;

      SELECT to_jsonb(pt.*)
      INTO v_master_before
      FROM public.product_tags pt
      WHERE pt.id = v_target_record_id;

      IF v_master_before IS NULL THEN
        RAISE EXCEPTION 'Tag not found for delete_request: %', v_target_record_id;
      END IF;

      IF v_tag_label IS DISTINCT FROM (v_master_before ->> 'tag_label') THEN
        RAISE EXCEPTION 'Tag delete_request payload label does not match target tag row';
      END IF;

      v_tag_id := v_target_record_id;
      DELETE FROM public.product_tags WHERE id = v_target_record_id;
    END IF;

    EXECUTE format(
      'UPDATE public.%I
         SET status = ''approved'',
             target_record_id = $2,
             reviewed_by = auth.uid(),
             reviewed_at = now(),
             review_notes = ''Approved and mapped to public.product_tags'',
             updated_at = now()
       WHERE id = $1',
      p_draft_table
    )
    USING p_draft_id, v_tag_id;

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
      v_payload,
      v_before,
      v_after,
      CASE WHEN v_operation = 'delete_request' THEN 'Tag delete_request approved (public.product_tags)' ELSE 'Tag create approved (public.product_tags)' END
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', 'approved',
      'draft_table', p_draft_table,
      'draft_id', p_draft_id,
      'target_record_id', v_tag_id,
      'tag_key', v_tag_key
    );
  END IF;

  IF p_draft_table = 'catalogue_alias_drafts' THEN
    IF coalesce(v_payload ->> 'scope', '') <> 'product_alias' THEN
      RAISE EXCEPTION 'Unexpected payload scope "%", expected "product_alias"', coalesce(v_payload ->> 'scope', '');
    END IF;

    BEGIN
      v_product_id := nullif(btrim(v_payload ->> 'product_id'), '')::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Alias draft requires valid product_id uuid';
    END;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Alias draft requires product_id';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = v_product_id) THEN
      RAISE EXCEPTION 'Product not found for alias draft: %', v_product_id;
    END IF;

    v_alias_text := nullif(btrim(coalesce(v_payload ->> 'alias_text', v_payload ->> 'alias')), '');
    IF v_alias_text IS NULL THEN
      RAISE EXCEPTION 'Alias draft requires alias or alias_text in payload';
    END IF;

    v_canonical_name := nullif(btrim(coalesce(v_payload ->> 'canonical_name', v_payload ->> 'product_name')), '');
    IF v_canonical_name IS NULL THEN
      SELECT p.name
      INTO v_canonical_name
      FROM public.products p
      WHERE p.id = v_product_id;
    END IF;

    IF v_canonical_name IS NULL OR btrim(v_canonical_name) = '' THEN
      RAISE EXCEPTION 'Alias draft requires canonical_name or resolvable products.name for product_id %', v_product_id;
    END IF;

    IF v_operation = 'create' THEN
      INSERT INTO public.product_aliases (alias_text, canonical_name, product_id)
      VALUES (v_alias_text, v_canonical_name, v_product_id)
      RETURNING id INTO v_alias_id;

      v_target_record_id := v_alias_id;
    ELSIF v_operation = 'update' THEN
      IF v_target_record_id IS NULL THEN
        RAISE EXCEPTION 'Alias update requires target_record_id';
      END IF;

      SELECT to_jsonb(pa.*)
      INTO v_master_before
      FROM public.product_aliases pa
      WHERE pa.id = v_target_record_id
      FOR UPDATE;

      IF v_master_before IS NULL THEN
        RAISE EXCEPTION 'Alias not found for update: %', v_target_record_id;
      END IF;

      IF (v_master_before ->> 'product_id')::uuid IS DISTINCT FROM v_product_id THEN
        RAISE EXCEPTION 'Alias update payload product_id does not match target row';
      END IF;

      UPDATE public.product_aliases pa
      SET
        alias_text = v_alias_text,
        canonical_name = v_canonical_name,
        product_id = v_product_id
      WHERE pa.id = v_target_record_id
      RETURNING pa.id INTO v_alias_id;
    ELSIF v_operation = 'delete_request' THEN
      IF v_target_record_id IS NULL THEN
        RAISE EXCEPTION 'Alias delete_request requires target_record_id';
      END IF;

      SELECT to_jsonb(pa.*)
      INTO v_master_before
      FROM public.product_aliases pa
      WHERE pa.id = v_target_record_id;

      IF v_master_before IS NULL THEN
        RAISE EXCEPTION 'Alias not found for delete_request: %', v_target_record_id;
      END IF;

      IF (v_master_before ->> 'product_id')::uuid IS DISTINCT FROM v_product_id THEN
        RAISE EXCEPTION 'Alias delete_request payload product_id does not match target row';
      END IF;

      v_alias_id := v_target_record_id;
      DELETE FROM public.product_aliases WHERE id = v_target_record_id;
    ELSE
      RAISE EXCEPTION 'Unsupported alias draft operation: %', v_operation;
    END IF;

    EXECUTE format(
      'UPDATE public.%I
         SET status = ''approved'',
             target_record_id = $2,
             reviewed_by = auth.uid(),
             reviewed_at = now(),
             review_notes = ''Approved and mapped to public.product_aliases'',
             updated_at = now()
       WHERE id = $1',
      p_draft_table
    )
    USING p_draft_id, v_alias_id;

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
      v_payload,
      v_before,
      v_after,
      'Alias draft approved and mapped to public.product_aliases'
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', 'approved',
      'draft_table', p_draft_table,
      'draft_id', p_draft_id,
      'target_record_id', v_alias_id
    );
  END IF;

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
    'approve_blocked_mapping_not_finalized',
    auth.uid(),
    v_payload,
    v_before,
    NULL,
    'Approval mapping not finalized for this draft type'
  );

  RETURN jsonb_build_object(
    'ok', false,
    'action', 'approve_blocked_mapping_not_finalized',
    'draft_table', p_draft_table,
    'draft_id', p_draft_id,
    'message', 'Approval mapping not finalized for this draft type'
  );
END;
$_$;

REVOKE ALL ON FUNCTION public.catalogue_extract_reviewed_intake_barcode(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.catalogue_validate_intake_barcode(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.catalogue_claim_intake_barcode(text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_catalogue_product_draft_v1(text, uuid, jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.catalogue_extract_reviewed_intake_barcode(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_validate_intake_barcode(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_claim_intake_barcode(text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_approve_product_draft_atomic_v1(text, uuid, jsonb, jsonb, text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_catalogue_product_draft_v1(text, uuid, jsonb) TO authenticated, service_role;
