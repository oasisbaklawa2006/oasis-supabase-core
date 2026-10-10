-- Core #404: approve_catalogue_draft_internal() allows catalogue_media_submissions
-- into its draft-table allowlist but has no dedicated approval branch for it, so
-- every media-submission approval attempt silently falls through to the generic
-- approve_blocked_mapping_not_finalized result (ok:false). This establishes the
-- missing branch, atomically mapping an approved media draft onto public.product_media,
-- while preserving fail-closed behaviour for anything the branch does not recognize.
--
-- Scope: approval-time mapping only. Submission (catalogue_media_submissions insert)
-- and reviewer RBAC (public.is_catalogue_reviewer()) are unchanged and already enforced
-- by the surrounding function. No RLS, grant, or schema change beyond this function body.

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
  v_media_id uuid;
  v_media_type text;
  v_media_file_url text;
  v_media_angle text;
  v_media_alt_text text;
  v_allowed_media_types text[] := ARRAY[
    'raw_photo', 'hero_image', 'white_background', 'lifestyle', 'closeup',
    'side_angle', 'top_angle', '45_angle', 'hamper_open', 'hamper_closed',
    'video', 'label_image', 'source_pdf_page'
  ];
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

  IF p_draft_table = 'catalogue_media_submissions' THEN
    v_product_id := nullif(v_payload ->> 'product_id', '')::uuid;
    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Media draft requires product_id in payload';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = v_product_id) THEN
      RAISE EXCEPTION 'Media draft product_id does not reference an existing product: %', v_product_id;
    END IF;

    v_media_angle := nullif(v_payload ->> 'angle', '');
    v_media_alt_text := nullif(v_payload ->> 'alt_text', '');

    IF v_operation = 'create' THEN
      v_media_type := nullif(btrim(v_payload ->> 'type'), '');
      IF v_media_type IS NULL OR NOT (v_media_type = ANY (v_allowed_media_types)) THEN
        RAISE EXCEPTION 'Unsupported or missing media type: %', coalesce(v_media_type, '(null)');
      END IF;

      v_media_file_url := nullif(btrim(coalesce(v_payload ->> 'file_url', '')), '');
      IF v_media_file_url IS NULL THEN
        RAISE EXCEPTION 'Media create draft requires file_url in payload';
      END IF;

      INSERT INTO public.product_media (product_id, file_url, type, status, angle, alt_text)
      VALUES (v_product_id, v_media_file_url, v_media_type, 'approved', v_media_angle, v_media_alt_text)
      RETURNING id INTO v_media_id;
    ELSIF v_operation = 'update' THEN
      v_media_type := nullif(btrim(v_payload ->> 'type'), '');
      IF v_media_type IS NULL OR NOT (v_media_type = ANY (v_allowed_media_types)) THEN
        RAISE EXCEPTION 'Unsupported or missing media type: %', coalesce(v_media_type, '(null)');
      END IF;

      IF v_target_record_id IS NULL THEN
        RAISE EXCEPTION 'Media update draft requires target_record_id';
      END IF;

      SELECT to_jsonb(pm.*)
      INTO v_master_before
      FROM public.product_media pm
      WHERE pm.id = v_target_record_id
      FOR UPDATE;

      IF v_master_before IS NULL THEN
        RAISE EXCEPTION 'Media row not found for update: %', v_target_record_id;
      END IF;

      IF (v_master_before ->> 'product_id')::uuid IS DISTINCT FROM v_product_id THEN
        RAISE EXCEPTION 'Media update payload product_id does not match target row';
      END IF;

      v_media_file_url := nullif(btrim(v_payload ->> 'file_url'), '');

      UPDATE public.product_media pm
      SET
        file_url = coalesce(v_media_file_url, pm.file_url),
        type = v_media_type,
        angle = CASE WHEN v_payload ? 'angle' THEN v_media_angle ELSE pm.angle END,
        alt_text = CASE WHEN v_payload ? 'alt_text' THEN v_media_alt_text ELSE pm.alt_text END,
        status = 'approved'
      WHERE pm.id = v_target_record_id
      RETURNING pm.id INTO v_media_id;
    ELSIF v_operation = 'delete_request' THEN
      IF v_target_record_id IS NULL THEN
        RAISE EXCEPTION 'Media delete_request requires target_record_id';
      END IF;

      SELECT to_jsonb(pm.*)
      INTO v_master_before
      FROM public.product_media pm
      WHERE pm.id = v_target_record_id;

      IF v_master_before IS NULL THEN
        RAISE EXCEPTION 'Media row not found for delete_request: %', v_target_record_id;
      END IF;

      IF (v_master_before ->> 'product_id')::uuid IS DISTINCT FROM v_product_id THEN
        RAISE EXCEPTION 'Media delete_request payload product_id does not match target row';
      END IF;

      v_media_id := v_target_record_id;
      DELETE FROM public.product_media WHERE id = v_target_record_id;
    ELSE
      RAISE EXCEPTION 'Unsupported media draft operation: %', v_operation;
    END IF;

    EXECUTE format(
      'UPDATE public.%I
         SET status = ''approved'',
             target_record_id = $2,
             reviewed_by = auth.uid(),
             reviewed_at = now(),
             review_notes = ''Approved and mapped to public.product_media'',
             updated_at = now()
       WHERE id = $1',
      p_draft_table
    )
    USING p_draft_id, v_media_id;

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
      'Media draft approved and mapped to public.product_media'
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', 'approved',
      'draft_table', p_draft_table,
      'draft_id', p_draft_id,
      'target_record_id', v_media_id
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

COMMENT ON FUNCTION public.approve_catalogue_draft_internal(text, uuid) IS
  'Governed catalogue draft approval dispatcher. Core #404: adds the catalogue_media_submissions branch, atomically mapping an approved media draft onto public.product_media (create/update/delete_request), fail-closed on unknown media type, missing product_id/file_url, or an unresolved target row. catalogue_bom_drafts, catalogue_moq_drafts and catalogue_pricing_drafts remain unmapped and intentionally fall through to approve_blocked_mapping_not_finalized.';

-- No prior migration explicitly scoped execute privilege on this function; apply the
-- same PUBLIC/anon lockout + authenticated/service_role grant used by its sibling
-- catalogue draft RPCs. The function's own is_catalogue_reviewer() check remains the
-- authoritative gate regardless.
REVOKE ALL ON FUNCTION public.approve_catalogue_draft_internal(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_catalogue_draft_internal(text, uuid) TO authenticated, service_role;
