


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "cleanup_archive";


ALTER SCHEMA "cleanup_archive" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."activate_company_on_application_approval"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'approved') THEN
    UPDATE public.companies
    SET status = 'active'
    WHERE business_name = NEW.business_name
      AND COALESCE(status,'pending') <> 'active';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."activate_company_on_application_approval"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."app_verse_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin new.updated_at = now(); return new; end;
$$;


ALTER FUNCTION "public"."app_verse_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_operational_event_v1"("p_event_type" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_title" "text", "p_source_application" "text", "p_correlation_id" "text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb", "p_order_id" "uuid" DEFAULT NULL::"uuid", "p_customer_id" "uuid" DEFAULT NULL::"uuid", "p_queue_item_id" "uuid" DEFAULT NULL::"uuid", "p_actor_id" "uuid" DEFAULT NULL::"uuid", "p_actor_role" "text" DEFAULT NULL::"text", "p_actor_department" "text" DEFAULT NULL::"text", "p_visibility" "text" DEFAULT 'internal'::"text", "p_severity" "text" DEFAULT 'info'::"text", "p_message" "text" DEFAULT NULL::"text", "p_reason_code" "text" DEFAULT NULL::"text", "p_reason_text" "text" DEFAULT NULL::"text", "p_idempotency_key" "text" DEFAULT NULL::"text", "p_event_version" integer DEFAULT 1, "p_command_name" "text" DEFAULT NULL::"text", "p_command_id" "text" DEFAULT NULL::"text", "p_causation_id" "text" DEFAULT NULL::"text", "p_occurred_at" timestamp with time zone DEFAULT "now"()) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$ declare v_actor_id uuid:=coalesce(p_actor_id,auth.uid()); v_fingerprint text; v_existing_id uuid; v_existing_fingerprint text; begin if auth.role()<>'service_role' then if auth.uid() is null then raise exception 'authentication required'; end if; if v_actor_id is distinct from auth.uid() then raise exception 'actor identity mismatch'; end if; if not public.is_internal_staff(auth.uid()) then raise exception 'internal staff authority required'; end if; end if; if nullif(btrim(p_event_type),'') is null or nullif(btrim(p_entity_type),'') is null or p_entity_id is null or nullif(btrim(p_title),'') is null or nullif(btrim(p_source_application),'') is null or nullif(btrim(p_correlation_id),'') is null then raise exception 'event_type, entity_type, entity_id, title, source_application and correlation_id are required'; end if; if p_event_version<1 then raise exception 'event_version must be positive'; end if; v_fingerprint:=md5(concat_ws('|',p_event_type,p_entity_type,p_entity_id::text,p_title,p_source_application,p_correlation_id,coalesce(p_metadata,'{}'::jsonb)::text,coalesce(p_order_id::text,''),coalesce(p_customer_id::text,''),coalesce(p_queue_item_id::text,''),coalesce(v_actor_id::text,''),coalesce(p_visibility,''),coalesce(p_severity,''),coalesce(p_command_name,''),coalesce(p_command_id,''),coalesce(p_causation_id,''),p_event_version::text)); if p_idempotency_key is not null then select id,payload_fingerprint into v_existing_id,v_existing_fingerprint from public.operational_events where source_application=p_source_application and idempotency_key=p_idempotency_key; if v_existing_id is not null then if v_existing_fingerprint<>v_fingerprint then raise exception 'idempotency key conflict'; end if; return v_existing_id; end if; end if; begin insert into public.operational_events(event_type,entity_type,entity_id,order_id,customer_id,queue_item_id,actor_id,actor_role,actor_department,visibility,severity,title,message,reason_code,reason_text,metadata,correlation_id,idempotency_key,source_application,event_version,command_name,command_id,causation_id,occurred_at,payload_fingerprint) values(p_event_type,p_entity_type,p_entity_id,p_order_id,p_customer_id,p_queue_item_id,v_actor_id,p_actor_role,p_actor_department,p_visibility,p_severity,p_title,p_message,p_reason_code,p_reason_text,coalesce(p_metadata,'{}'::jsonb),p_correlation_id,p_idempotency_key,p_source_application,p_event_version,p_command_name,p_command_id,p_causation_id,p_occurred_at,v_fingerprint) returning id into v_existing_id; return v_existing_id; exception when unique_violation then if p_idempotency_key is null then raise; end if; select id,payload_fingerprint into v_existing_id,v_existing_fingerprint from public.operational_events where source_application=p_source_application and idempotency_key=p_idempotency_key; if v_existing_id is null or v_existing_fingerprint<>v_fingerprint then raise exception 'idempotency key conflict'; end if; return v_existing_id; end; end; $$;


ALTER FUNCTION "public"."append_operational_event_v1"("p_event_type" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_title" "text", "p_source_application" "text", "p_correlation_id" "text", "p_metadata" "jsonb", "p_order_id" "uuid", "p_customer_id" "uuid", "p_queue_item_id" "uuid", "p_actor_id" "uuid", "p_actor_role" "text", "p_actor_department" "text", "p_visibility" "text", "p_severity" "text", "p_message" "text", "p_reason_code" "text", "p_reason_text" "text", "p_idempotency_key" "text", "p_event_version" integer, "p_command_name" "text", "p_command_id" "text", "p_causation_id" "text", "p_occurred_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_alias_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_alias_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_alias_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_bom_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_bom_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_bom_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
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

  -- -------------------------------------------------------------------------
  -- PRESERVED VERBATIM: catalogue_product_drafts branch (Central staging baseline)
  -- -------------------------------------------------------------------------
  IF p_draft_table = 'catalogue_product_drafts' THEN
    IF v_operation = 'create' OR v_target_record_id IS NULL THEN
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
        created_at
      )
      VALUES (
        coalesce(
          nullif(v_payload #>> '{sku_draft,sku}', ''),
          'DRAFT-' || upper(substr(gen_random_uuid()::text, 1, 8))
        ),
        coalesce(v_payload #>> '{identity,product_name}', 'Unnamed Product'),
        coalesce(v_payload #>> '{identity,category}', 'Uncategorized'),
        v_payload #>> '{identity,subcategory}',
        coalesce(
          v_payload #>> '{identity,description}',
          v_payload #>> '{identity,short_description}'
        ),
        v_payload #>> '{identity,main_department}',
        nullif(v_payload #>> '{identity,production_department}', ''),
        v_payload #>> '{pricing,hsn}',
        nullif(v_payload #>> '{pricing,gst_rate}', '')::numeric,
        nullif(v_payload #>> '{pricing,gst_rate}', '')::numeric,
        nullif(v_payload #>> '{pricing,mrp}', '')::numeric,
        nullif(v_payload #>> '{pricing,b2b_price}', '')::numeric,
        nullif(v_payload #>> '{pricing,bulk_price}', '')::numeric,
        nullif(v_payload #>> '{pricing,wholesale_price}', '')::numeric,
        nullif(v_payload #>> '{pricing,wholesale_price}', '')::numeric,
        v_payload #>> '{uom,primary_uom}',
        true,
        false,
        coalesce(
          v_payload #>> '{packing,pack_preview}',
          v_payload #>> '{packing,primary_pack_type}'
        ),
        v_payload #>> '{compliance,ingredients}',
        v_payload #>> '{compliance,allergen_information}',
        v_payload #>> '{compliance,nutritional_information}',
        coalesce(v_payload #>> '{identity,product_type}', 'General'),
        now()
      )
      RETURNING id INTO v_product_id;
    ELSE
      UPDATE public.products
      SET
        sku = coalesce(
          nullif(v_payload #>> '{sku_draft,sku}', ''),
          sku
        ),
        name = coalesce(v_payload #>> '{identity,product_name}', name),
        category = coalesce(v_payload #>> '{identity,category}', category),
        sub_category = coalesce(v_payload #>> '{identity,subcategory}', sub_category),
        description = coalesce(
          v_payload #>> '{identity,description}',
          v_payload #>> '{identity,short_description}',
          description
        ),
        department = coalesce(v_payload #>> '{identity,main_department}', department),
        production_department = coalesce(
          nullif(v_payload #>> '{identity,production_department}', ''),
          production_department
        ),
        hsn_code = coalesce(v_payload #>> '{pricing,hsn}', hsn_code),
        gst_rate = coalesce(nullif(v_payload #>> '{pricing,gst_rate}', '')::numeric, gst_rate),
        gst_percentage = coalesce(nullif(v_payload #>> '{pricing,gst_rate}', '')::numeric, gst_percentage),
        mrp = coalesce(nullif(v_payload #>> '{pricing,mrp}', '')::numeric, mrp),
        price_b2b = coalesce(nullif(v_payload #>> '{pricing,b2b_price}', '')::numeric, price_b2b),
        price_bulk = coalesce(nullif(v_payload #>> '{pricing,bulk_price}', '')::numeric, price_bulk),
        price_wholesale = coalesce(nullif(v_payload #>> '{pricing,wholesale_price}', '')::numeric, price_wholesale),
        wholesale_price = coalesce(nullif(v_payload #>> '{pricing,wholesale_price}', '')::numeric, wholesale_price),
        uom = coalesce(v_payload #>> '{uom,primary_uom}', uom),
        pack_size = coalesce(
          v_payload #>> '{packing,pack_preview}',
          v_payload #>> '{packing,primary_pack_type}',
          pack_size
        ),
        ingredients = coalesce(v_payload #>> '{compliance,ingredients}', ingredients),
        allergen_warnings = coalesce(v_payload #>> '{compliance,allergen_information}', allergen_warnings),
        nutrition_facts = coalesce(v_payload #>> '{compliance,nutritional_information}', nutrition_facts),
        product_family = coalesce(v_payload #>> '{identity,product_type}', product_family)
      WHERE id = v_target_record_id
      RETURNING id INTO v_product_id;

      IF v_product_id IS NULL THEN
        RAISE EXCEPTION 'Target product not found: %', v_target_record_id;
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
      v_payload,
      v_before,
      v_after,
      'Product draft approved and mapped to public.products'
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', 'approved',
      'draft_table', p_draft_table,
      'draft_id', p_draft_id,
      'target_record_id', v_product_id
    );
  END IF;
  -- -------------------------------------------------------------------------
  -- END PRESERVED product branch
  -- -------------------------------------------------------------------------

  -- -------------------------------------------------------------------------
  -- catalogue_tag_drafts -> public.product_tags
  -- -------------------------------------------------------------------------
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

  -- -------------------------------------------------------------------------
  -- catalogue_alias_drafts -> public.product_aliases
  -- -------------------------------------------------------------------------
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

  -- -------------------------------------------------------------------------
  -- Unmapped draft types (BOM, MOQ, pricing, media) — unchanged soft block
  -- -------------------------------------------------------------------------
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


ALTER FUNCTION "public"."approve_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_media_submission"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_media_submissions', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_media_submission"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_moq_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_moq_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_moq_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_pricing_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_pricing_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_pricing_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_product_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_product_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_product_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_catalogue_tag_draft"("draft_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.approve_catalogue_draft_internal('catalogue_tag_drafts', draft_id);
$$;


ALTER FUNCTION "public"."approve_catalogue_tag_draft"("draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_status text;
  v_extraction_request_key text;
  v_readiness_dimensions jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to approve sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  IF NULLIF(trim(p_expected_extraction_request_key), '') IS NULL THEN
    RAISE EXCEPTION 'Expected extraction request key is required';
  END IF;

  SELECT d.status, d.extraction_request_key, d.readiness_dimensions
  INTO v_status, v_extraction_request_key, v_readiness_dimensions
  FROM public.sales_order_drafts d
  WHERE d.id = p_draft_id
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Sales order draft not found';
  END IF;

  IF v_status <> 'UNDER_REVIEW' THEN
    RAISE EXCEPTION 'Approve for SO only allowed from UNDER_REVIEW, currently %', v_status;
  END IF;

  IF NULLIF(trim(v_extraction_request_key), '') IS NULL THEN
    RAISE EXCEPTION 'Draft extraction request key is missing';
  END IF;

  IF v_extraction_request_key IS DISTINCT FROM trim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'Extraction version mismatch for draft %', p_draft_id;
  END IF;

  -- Server-owned readiness: validate persisted dimensions only (never client metadata).
  PERFORM public.validate_sales_order_draft_readiness(v_readiness_dimensions);

  UPDATE public.sales_order_drafts
  SET
    status = 'APPROVED_FOR_SO',
    approver_id = p_actor_id,
    approver_name = p_actor_name,
    review_notes = COALESCE(p_review_notes, review_notes),
    updated_by = p_actor_id
  WHERE id = p_draft_id;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    p_draft_id,
    'APPROVE',
    'UNDER_REVIEW',
    'APPROVED_FOR_SO',
    p_actor_id,
    p_actor_name,
    p_metadata
  );

  RETURN p_draft_id;
END;
$$;


ALTER FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") IS 'Atomically validates extraction version and persisted readiness, approves draft for SO, and appends audit row.';



CREATE OR REPLACE FUNCTION "public"."assign_order_number_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_year integer;
  v_next bigint;
BEGIN
  IF NEW.order_number IS NOT NULL AND btrim(NEW.order_number) <> '' THEN
    RETURN NEW;
  END IF;

  v_year := (EXTRACT(YEAR FROM COALESCE(NEW.created_at, now()) AT TIME ZONE 'UTC'))::integer;

  PERFORM pg_advisory_xact_lock(58492001, v_year);

  SELECT COALESCE(MAX(substring(o.order_number FROM '^SO-[0-9]{4}-([0-9]+)$')::bigint), 0) + 1
  INTO v_next
  FROM public.orders o
  WHERE o.order_number LIKE 'SO-' || v_year::text || '-%';

  NEW.order_number := 'SO-' || v_year::text || '-' || lpad(v_next::text, 6, '0');
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."assign_order_number_on_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auth_buyer_company_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT u.company_id FROM public.users u WHERE u.id = auth.uid() LIMIT 1),
    (SELECT p.company_id FROM public.profiles p WHERE p.id = auth.uid() LIMIT 1)
  );
$$;


ALTER FUNCTION "public"."auth_buyer_company_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_orders_when_frozen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  frozen boolean;
BEGIN
  IF NEW.company_id IS NULL THEN RETURN NEW; END IF;
  -- Allow draft/cart so user can browse; block real submission
  IF NEW.status IN ('draft','cart') THEN RETURN NEW; END IF;

  SELECT is_frozen INTO frozen FROM public.companies WHERE id = NEW.company_id;
  IF COALESCE(frozen,false) THEN
    RAISE EXCEPTION 'CREDIT_FROZEN: Company credit is locked. Settle outstanding balance to resume operations.'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."block_orders_when_frozen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."buyer_product_prices_v1"() RETURNS TABLE("product_id" "uuid", "selling_price" numeric, "currency" "text", "uom" "text", "gst_rate" numeric, "tax_inclusive" boolean, "applied_discount_percent" numeric, "minimum_order_quantity" numeric, "minimum_order_uom" "text", "order_increment" numeric, "order_increment_uom" "text", "valid_from" "date", "valid_until" "date")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'auth'
    AS $$
  with buyer as (
    select
      p.company_id,
      greatest(least(coalesce(c.discount_percentage, 0), 100), 0)::numeric as discount_percent
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
    limit 1
  ), ranked_prices as (
    select
      r.product_id,
      coalesce(r.calculated_price, r.base_price)::numeric as listed_price,
      r.currency,
      r.uom,
      r.gst_rate,
      coalesce(r.tax_inclusive, false) as tax_inclusive,
      r.valid_from,
      r.valid_until,
      row_number() over (
        partition by r.product_id
        order by r.valid_from desc nulls last,
                 r.approved_at desc nulls last,
                 r.updated_at desc nulls last,
                 r.id desc
      ) as rn
    from public.product_pricing_rules r
    join public.published_products_v1() pp on pp.product_id = r.product_id
    where lower(coalesce(r.price_channel, '')) = 'b2b'
      and lower(coalesce(r.approval_status, '')) = 'approved'
      and coalesce(r.calculated_price, r.base_price) > 0
      and (r.valid_from is null or r.valid_from <= current_date)
      and (r.valid_until is null or r.valid_until >= current_date)
  ), b2b_moq as (
    select
      m.product_id,
      case when coalesce(m.moq_applicable, true) then m.moq_value::numeric end as moq_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.moq_uom), '') end as moq_uom,
      case when coalesce(m.moq_applicable, true) then m.increment_value::numeric end as increment_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.increment_uom), '') end as increment_uom,
      row_number() over (
        partition by m.product_id
        order by m.updated_at desc nulls last, m.created_at desc nulls last, m.id desc
      ) as rn
    from public.product_moq_rules m
    where lower(coalesce(m.channel, '')) = 'b2b'
  )
  select
    rp.product_id,
    round(rp.listed_price * (1 - b.discount_percent / 100), 2) as selling_price,
    coalesce(nullif(btrim(rp.currency), ''), 'INR') as currency,
    rp.uom,
    rp.gst_rate,
    rp.tax_inclusive,
    b.discount_percent as applied_discount_percent,
    coalesce(
      bm.moq_value,
      p.moq_value::numeric,
      p.moq_packs::numeric,
      p.moq::numeric
    ) as minimum_order_quantity,
    coalesce(
      bm.moq_uom,
      nullif(btrim(p.moq_uom), ''),
      case when p.moq_packs is not null then 'pack' end,
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) as minimum_order_uom,
    coalesce(
      bm.increment_value,
      p.increment_value::numeric,
      1::numeric
    ) as order_increment,
    coalesce(
      bm.increment_uom,
      nullif(btrim(p.increment_uom), ''),
      nullif(btrim(p.moq_uom), ''),
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) as order_increment_uom,
    rp.valid_from,
    rp.valid_until
  from ranked_prices rp
  cross join buyer b
  join public.products p on p.id = rp.product_id
  left join b2b_moq bm on bm.product_id = rp.product_id and bm.rn = 1
  where rp.rn = 1
  order by rp.product_id;
$$;


ALTER FUNCTION "public"."buyer_product_prices_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."buyer_product_prices_v1"() IS 'Authenticated buyer price contract v1. Returns one current positive approved B2B selling price and customer-safe MOQ/increment rules per published product for approved buyers linked to active, non-frozen companies.';



CREATE OR REPLACE FUNCTION "public"."calculate_retry_delay_v1"("p_policy_key" "text", "p_attempt_count" integer, "p_jitter_seed" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_policy public.retry_policies%rowtype;
  v_raw numeric;
  v_jitter_span numeric;
  v_jitter numeric := 0;
begin
  if p_attempt_count < 1 then
    raise exception 'attempt_count must be positive';
  end if;

  select * into v_policy
  from public.retry_policies
  where policy_key = p_policy_key and is_active;

  if not found then
    raise exception 'active retry policy not found: %', p_policy_key;
  end if;

  v_raw := least(
    v_policy.max_delay_seconds::numeric,
    v_policy.base_delay_seconds::numeric * power(v_policy.backoff_multiplier, p_attempt_count - 1)
  );

  if v_policy.jitter_percent > 0 and p_jitter_seed is not null then
    v_jitter_span := v_raw * v_policy.jitter_percent / 100.0;
    v_jitter := ((abs(hashtext(p_jitter_seed || ':' || p_attempt_count::text)) % 2001)::numeric / 1000.0 - 1.0) * v_jitter_span;
  end if;

  return greatest(0, least(v_policy.max_delay_seconds, round(v_raw + v_jitter)::integer));
end;
$$;


ALTER FUNCTION "public"."calculate_retry_delay_v1"("p_policy_key" "text", "p_attempt_count" integer, "p_jitter_seed" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."catalogue_slugify_tag_part"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT trim(both '-' FROM lower(regexp_replace(coalesce(nullif(btrim(p_text), ''), 'general'), '[^a-zA-Z0-9]+', '-', 'g')));
$$;


ALTER FUNCTION "public"."catalogue_slugify_tag_part"("p_text" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."notification_outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_phone" "text",
    "recipient_email" "text",
    "message_body" "text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text",
    "status" "text" DEFAULT 'pending'::"text",
    "error_log" "text",
    "event_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sent_at" timestamp with time zone,
    "source_application" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "channel" "text" NOT NULL,
    "idempotency_key" "text",
    "event_id" "uuid",
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "max_attempts" integer DEFAULT 5 NOT NULL,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "locked_at" timestamp with time zone,
    "locked_by" "text",
    "provider_message_id" "text",
    "last_attempt_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_outbox_attempts_check" CHECK ((("attempt_count" >= 0) AND ("max_attempts" > 0) AND ("attempt_count" <= "max_attempts"))),
    CONSTRAINT "notification_outbox_channel_check" CHECK (("channel" = ANY (ARRAY['email'::"text", 'whatsapp'::"text", 'sms'::"text", 'push'::"text", 'unknown'::"text"]))),
    CONSTRAINT "notification_outbox_recipient_check" CHECK (((("channel" = 'email'::"text") AND ("recipient_email" IS NOT NULL)) OR (("channel" = ANY (ARRAY['whatsapp'::"text", 'sms'::"text"])) AND ("recipient_phone" IS NOT NULL)) OR ("channel" = ANY (ARRAY['push'::"text", 'unknown'::"text"])))),
    CONSTRAINT "notification_outbox_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'sent'::"text", 'retry'::"text", 'failed'::"text", 'quarantined'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."notification_outbox" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_notification_batch_v1"("p_worker_id" "text", "p_batch_size" integer DEFAULT 25, "p_lease_seconds" integer DEFAULT 120) RETURNS SETOF "public"."notification_outbox"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if auth.role() <> 'service_role' then raise exception 'service role required'; end if;
  if nullif(btrim(p_worker_id), '') is null then raise exception 'worker_id required'; end if;
  if p_batch_size < 1 or p_batch_size > 100 then raise exception 'batch_size must be between 1 and 100'; end if;
  return query with candidates as (
    select id from public.notification_outbox where status in ('pending','retry') and next_attempt_at <= now() and attempt_count < max_attempts and (locked_at is null or locked_at < now() - make_interval(secs => p_lease_seconds))
    order by case priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end, created_at for update skip locked limit p_batch_size
  ) update public.notification_outbox n set status='processing',locked_at=now(),locked_by=p_worker_id,last_attempt_at=now(),attempt_count=n.attempt_count+1,updated_at=now() from candidates c where n.id=c.id returning n.*;
end; $$;


ALTER FUNCTION "public"."claim_notification_batch_v1"("p_worker_id" "text", "p_batch_size" integer, "p_lease_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_provider_message_id" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if auth.role() <> 'service_role' then raise exception 'service role required'; end if;
  update public.notification_outbox set status='sent',sent_at=now(),provider_message_id=p_provider_message_id,locked_at=null,locked_by=null,error_log=null,updated_at=now() where id=p_notification_id and status='processing' and locked_by=p_worker_id;
  if not found then raise exception 'notification lease not owned'; end if;
end; $$;


ALTER FUNCTION "public"."complete_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_provider_message_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_packet_id uuid;
  v_draft_id uuid;
  v_line jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to create sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  v_packet_id := (p_header->>'packet_id')::uuid;

  IF EXISTS (
    SELECT 1
    FROM public.sales_order_drafts d
    WHERE d.packet_id = v_packet_id
      AND d.status <> 'REJECTED'
  ) THEN
    RAISE EXCEPTION 'Active sales order draft already exists for packet';
  END IF;

  INSERT INTO public.sales_order_drafts (
    packet_id,
    extraction_request_key,
    status,
    client_owner_id,
    client_owner_name,
    order_creator_id,
    order_creator_name,
    order_handler_id,
    order_handler_name,
    approver_id,
    approver_name,
    company_id,
    company_name,
    readiness_overall_score,
    readiness_dimensions,
    original_whatsapp_text,
    ai_draft_snapshot,
    operator_final_snapshot,
    created_by,
    updated_by
  ) VALUES (
    v_packet_id,
    p_header->>'extraction_request_key',
    COALESCE(p_header->>'status', 'AI_DRAFT'),
    NULLIF(p_header->>'client_owner_id', '')::uuid,
    p_header->>'client_owner_name',
    NULLIF(p_header->>'order_creator_id', '')::uuid,
    p_header->>'order_creator_name',
    NULLIF(p_header->>'order_handler_id', '')::uuid,
    p_header->>'order_handler_name',
    NULLIF(p_header->>'approver_id', '')::uuid,
    p_header->>'approver_name',
    NULLIF(p_header->>'company_id', '')::uuid,
    p_header->>'company_name',
    COALESCE((p_header->>'readiness_overall_score')::integer, 0),
    COALESCE(p_header->'readiness_dimensions', '[]'::jsonb),
    COALESCE(p_header->>'original_whatsapp_text', ''),
    COALESCE(p_header->'ai_draft_snapshot', '{}'::jsonb),
    COALESCE(p_header->'operator_final_snapshot', '{}'::jsonb),
    p_actor_id,
    p_actor_id
  )
  RETURNING id INTO v_draft_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb))
  LOOP
    INSERT INTO public.sales_order_draft_lines (
      draft_id,
      line_index,
      product_id,
      product_name,
      sku,
      raw_quantity,
      raw_unit,
      normalized_quantity,
      normalized_unit,
      operator_quantity,
      original_text_span,
      conversion_explanation,
      product_confidence,
      quantity_confidence,
      ai_line_snapshot,
      operator_line_snapshot
    ) VALUES (
      v_draft_id,
      (v_line->>'line_index')::integer,
      NULLIF(v_line->>'product_id', '')::uuid,
      COALESCE(v_line->>'product_name', ''),
      v_line->>'sku',
      COALESCE((v_line->>'raw_quantity')::numeric, 0),
      v_line->>'raw_unit',
      NULLIF(v_line->>'normalized_quantity', '')::numeric,
      v_line->>'normalized_unit',
      NULLIF(v_line->>'operator_quantity', '')::numeric,
      v_line->>'original_text_span',
      v_line->>'conversion_explanation',
      NULLIF(v_line->>'product_confidence', '')::numeric,
      NULLIF(v_line->>'quantity_confidence', '')::numeric,
      COALESCE(v_line->'ai_line_snapshot', '{}'::jsonb),
      COALESCE(v_line->'operator_line_snapshot', '{}'::jsonb)
    );
  END LOOP;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    v_draft_id,
    'CREATE',
    NULL,
    'AI_DRAFT',
    p_actor_id,
    p_actor_name,
    p_audit_metadata
  );

  RETURN v_draft_id;
END;
$$;


ALTER FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") IS 'Atomically creates sales_order_drafts header, lines, and CREATE audit row.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_sales_order_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source" "text" DEFAULT 'whatsapp_inbound'::"text" NOT NULL,
    "source_message_id" "uuid" NOT NULL,
    "sender_phone" "text" NOT NULL,
    "customer_name" "text",
    "message_body" "text" NOT NULL,
    "resolved_product_id" "uuid",
    "resolved_sku" "text" NOT NULL,
    "resolved_product_name" "text",
    "confidence_band" "text" NOT NULL,
    "operator_decision" "text" NOT NULL,
    "status" "text" DEFAULT 'UNDER_REVIEW'::"text" NOT NULL,
    "quantity" numeric DEFAULT 1 NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_sales_order_drafts_confidence_band_check" CHECK (("confidence_band" = ANY (ARRAY['HIGH'::"text", 'MEDIUM'::"text", 'LOW'::"text"]))),
    CONSTRAINT "whatsapp_sales_order_drafts_operator_decision_check" CHECK (("operator_decision" = ANY (ARRAY['confirmed'::"text", 'alternative_selected'::"text"]))),
    CONSTRAINT "whatsapp_sales_order_drafts_quantity_check" CHECK (("quantity" > (0)::numeric)),
    CONSTRAINT "whatsapp_sales_order_drafts_source_check" CHECK (("source" = 'whatsapp_inbound'::"text")),
    CONSTRAINT "whatsapp_sales_order_drafts_status_check" CHECK (("status" = ANY (ARRAY['AI_DRAFT'::"text", 'UNDER_REVIEW'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."whatsapp_sales_order_drafts" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_sales_order_drafts" IS 'Phase 2E reviewable WhatsApp sales order drafts from operator confirm. Not a final sales order.';



CREATE OR REPLACE FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric DEFAULT 1) RETURNS "public"."whatsapp_sales_order_drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  msg public.whatsapp_inbound_messages;
  existing public.whatsapp_sales_order_drafts;
  inserted public.whatsapp_sales_order_drafts;
  draft_status TEXT;
  draft_quantity NUMERIC;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to create whatsapp sales order drafts';
  END IF;

  IF _source_message_id IS NULL THEN
    RAISE EXCEPTION 'source_message_id is required';
  END IF;

  IF _resolved_sku IS NULL OR btrim(_resolved_sku) = '' THEN
    RAISE EXCEPTION 'resolved_sku is required';
  END IF;

  IF _confidence_band NOT IN ('HIGH', 'MEDIUM', 'LOW') THEN
    RAISE EXCEPTION 'invalid confidence_band';
  END IF;

  IF _operator_decision NOT IN ('confirmed', 'alternative_selected') THEN
    RAISE EXCEPTION 'invalid operator_decision';
  END IF;

  IF _confidence_band = 'LOW' AND _operator_decision <> 'alternative_selected' THEN
    RAISE EXCEPTION 'LOW confidence requires alternative_selected operator decision';
  END IF;

  draft_quantity := COALESCE(_quantity, 1);
  IF draft_quantity <= 0 THEN
    RAISE EXCEPTION 'quantity must be positive';
  END IF;

  SELECT * INTO msg
  FROM public.whatsapp_inbound_messages
  WHERE id = _source_message_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source message not found';
  END IF;

  SELECT * INTO existing
  FROM public.whatsapp_sales_order_drafts
  WHERE source_message_id = _source_message_id
  LIMIT 1;

  IF FOUND THEN
    RETURN existing;
  END IF;

  draft_status := CASE
    WHEN _confidence_band = 'HIGH' THEN 'AI_DRAFT'
    ELSE 'UNDER_REVIEW'
  END;

  INSERT INTO public.whatsapp_sales_order_drafts (
    source_message_id,
    sender_phone,
    customer_name,
    message_body,
    resolved_product_id,
    resolved_sku,
    resolved_product_name,
    confidence_band,
    operator_decision,
    status,
    quantity,
    created_by
  )
  VALUES (
    msg.id,
    msg.sender_phone,
    msg.sender_name,
    msg.message_body,
    _resolved_product_id,
    btrim(_resolved_sku),
    NULLIF(btrim(_resolved_product_name), ''),
    _confidence_band,
    _operator_decision,
    draft_status,
    draft_quantity,
    auth.uid()
  )
  RETURNING * INTO inserted;

  INSERT INTO public.whatsapp_operator_decisions (
    source_message_id,
    action,
    sku,
    product_name,
    confidence_band,
    whatsapp_sales_order_draft_id,
    decided_by
  )
  VALUES (
    msg.id,
    'confirm',
    inserted.resolved_sku,
    inserted.resolved_product_name,
    inserted.confidence_band,
    inserted.id,
    auth.uid()
  );

  RETURN inserted;
END;
$$;


ALTER FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric) IS 'Phase 2E/2F operator confirm → whatsapp_sales_order_drafts only. Idempotent per source_message_id.';



CREATE OR REPLACE FUNCTION "public"."customer_import_normalize_gst"("p_gst" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ SELECT NULLIF(upper(regexp_replace(trim(COALESCE(p_gst, '')), '[^0-9A-Z]', '', 'g')), ''); $$;


ALTER FUNCTION "public"."customer_import_normalize_gst"("p_gst" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."customer_import_normalize_payment_terms"("p_terms" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ SELECT CASE WHEN lower(trim(COALESCE(p_terms, ''))) IN ('credit', 'cr', 'net', 'net30', 'net 30') THEN 'credit' WHEN lower(trim(COALESCE(p_terms, ''))) IN ('prepaid', 'prepaid', 'advance', 'cod', 'cash', 'upi', '') THEN 'prepaid' WHEN lower(trim(COALESCE(p_terms, ''))) LIKE '%credit%' THEN 'credit' ELSE NULL END; $$;


ALTER FUNCTION "public"."customer_import_normalize_payment_terms"("p_terms" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."customer_import_normalize_phone_last10"("p_phone" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ SELECT CASE WHEN length(d) >= 10 THEN right(d, 10) ELSE NULL END FROM (SELECT regexp_replace(trim(COALESCE(p_phone, '')), '\D', '', 'g') AS d) s; $$;


ALTER FUNCTION "public"."customer_import_normalize_phone_last10"("p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."customer_import_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;


ALTER FUNCTION "public"."customer_import_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."customer_order_items_v1"() RETURNS TABLE("order_id" "uuid", "item_id" "uuid", "product_id" "uuid", "sku" "text", "product_name" "text", "quantity" numeric, "pack_size" "text", "weight_kg" numeric, "packed_quantity" numeric)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'auth'
    AS $$
  with eligible_company as (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
    limit 1
  )
  select
    oi.order_id,
    oi.id as item_id,
    oi.product_id,
    nullif(btrim(p.sku), '') as sku,
    coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), ''), 'Product') as product_name,
    oi.quantity::numeric,
    nullif(btrim(oi.pack_size), '') as pack_size,
    oi.weight_kg::numeric,
    case
      when o.status in ('packed_ready', 'cleared_for_dispatch', 'dispatched')
        then oi.actual_packed_qty::numeric
      else null
    end as packed_quantity
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join eligible_company ec on ec.company_id = o.company_id
  left join public.products p on p.id = oi.product_id
  where coalesce(o.is_waste, false) is false
    and coalesce(o.is_duplicate, false) is false
  order by o.created_at desc, oi.order_id, oi.id;
$$;


ALTER FUNCTION "public"."customer_order_items_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."customer_order_items_v1"() IS 'Customer-safe order-line projection for an approved buyer company. Packed quantity is withheld until the order is packed-ready, cleared for dispatch, or dispatched.';



CREATE OR REPLACE FUNCTION "public"."customer_order_status_v1"() RETURNS TABLE("order_id" "uuid", "order_number" "text", "customer_stage" "text", "payment_stage" "text", "order_value" numeric, "total_weight_kg" numeric, "requested_dispatch_date" "date", "promised_dispatch_date" "date", "tracking_number" "text", "courier_name" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  with eligible_company as (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
    limit 1
  )
  select
    o.id as order_id,
    o.order_number,
    case
      when o.status in ('draft', 'submitted') then 'order_received'
      when o.status in ('awaiting_advance', 'awaiting_payment') then 'payment_pending'
      when o.status in ('manufacturing', 'in_production') then 'in_production'
      when o.status in ('assembled', 'packing') then 'packing'
      when o.status in ('packed_ready', 'cleared_for_dispatch') then 'ready_for_dispatch'
      when o.status = 'dispatched' then 'dispatched'
      else 'processing'
    end as customer_stage,
    case
      when o.payment_status in ('paid', 'advance_paid', 'verified_advance') then 'paid_or_verified'
      when o.payment_status in ('on_credit', 'short_term_credit') then 'credit_approved'
      when o.payment_status in ('under_review', 'awaiting_verification') then 'under_review'
      else 'payment_pending'
    end as payment_stage,
    o.sales_order_value as order_value,
    o.total_weight_kg,
    o.requested_dispatch_date,
    coalesce(o.admin_promised_date, o.system_estimated_date, o.estimated_despatch_date) as promised_dispatch_date,
    case when o.status = 'dispatched' then nullif(btrim(o.tracking_number), '') end as tracking_number,
    case when o.status = 'dispatched' then nullif(btrim(o.courier_name), '') end as courier_name,
    o.created_at,
    greatest(o.created_at, coalesce(o.closed_at, o.created_at), coalesce(o.finance_verified_at, o.created_at)) as updated_at
  from public.orders o
  join eligible_company ec on ec.company_id = o.company_id
  where coalesce(o.is_waste, false) is false
    and coalesce(o.is_duplicate, false) is false
  order by o.created_at desc, o.id;
$$;


ALTER FUNCTION "public"."customer_order_status_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."customer_order_status_v1"() IS 'Customer-safe order status projection for the authenticated user company. Excludes internal notes, staff identities, raw workflow metadata, payment proofs and logistics-sensitive fields.';



CREATE OR REPLACE FUNCTION "public"."customer_support_tickets_v1"() RETURNS TABLE("ticket_id" "uuid", "order_id" "text", "order_number" "text", "issue_type" "text", "description" "text", "customer_status" "text", "product_sku" "text", "quantity_affected" integer, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "first_response_due" timestamp with time zone, "resolution_due" timestamp with time zone, "resolved_at" timestamp with time zone, "customer_rating" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'auth'
    AS $_$
  with eligible_companies as (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union

    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  )
  select
    st.id as ticket_id,
    st.order_id,
    o.order_number,
    st.issue_type,
    st.description,
    case
      when lower(coalesce(st.status, '')) in ('resolved', 'closed') then 'resolved'
      when lower(coalesce(st.status, '')) in ('rejected', 'cancelled') then 'closed'
      when st.sla_first_response_at is not null then 'in_progress'
      else 'open'
    end as customer_status,
    st.product_sku,
    st.qty_affected as quantity_affected,
    st.created_at,
    st.updated_at,
    st.sla_first_response_due as first_response_due,
    st.sla_resolution_due as resolution_due,
    st.sla_resolved_at as resolved_at,
    st.customer_rating
  from public.support_tickets st
  join eligible_companies ec on ec.company_id = st.company_id
  left join public.orders o
    on st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
   and o.id = st.order_id::uuid
  order by st.created_at desc, st.id;
$_$;


ALTER FUNCTION "public"."customer_support_tickets_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."customer_support_tickets_v1"() IS 'Customer-safe support ticket projection scoped to the authenticated approved company.';



CREATE OR REPLACE FUNCTION "public"."dispatch_completion_evidence_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RAISE EXCEPTION 'dispatch_completion_evidence is append-only';
END;
$$;


ALTER FUNCTION "public"."dispatch_completion_evidence_immutable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_readiness_evidence_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RAISE EXCEPTION 'dispatch_readiness_evidence is append-only';
END;
$$;


ALTER FUNCTION "public"."dispatch_readiness_evidence_immutable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_release_lineage_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RAISE EXCEPTION 'dispatch_release_lineage is append-only';
END;
$$;


ALTER FUNCTION "public"."dispatch_release_lineage_immutable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_profile_approval_for_staff"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.role := upper(coalesce(NEW.role, NEW.role));

  IF public.is_staff_role(NEW.role) THEN
    NEW.is_approved := true;
    NEW.status := 'approved';
  ELSE
    IF NEW.status IS NULL OR btrim(NEW.status) = '' THEN
      NEW.status := CASE WHEN coalesce(NEW.is_approved, false) THEN 'approved' ELSE 'pending' END;
    ELSE
      NEW.status := lower(NEW.status);
    END IF;

    IF NEW.is_approved IS NULL THEN
      NEW.is_approved := NEW.status = 'approved';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_profile_approval_for_staff"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_sales_order_draft_immutable_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.original_whatsapp_text IS DISTINCT FROM OLD.original_whatsapp_text THEN
    RAISE EXCEPTION 'sales_order_drafts.original_whatsapp_text is immutable after create';
  END IF;
  IF NEW.ai_draft_snapshot IS DISTINCT FROM OLD.ai_draft_snapshot THEN
    RAISE EXCEPTION 'sales_order_drafts.ai_draft_snapshot is immutable after create';
  END IF;
  IF NEW.client_owner_id IS DISTINCT FROM OLD.client_owner_id THEN
    RAISE EXCEPTION 'sales_order_drafts.client_owner_id is immutable after create';
  END IF;
  IF NEW.client_owner_name IS DISTINCT FROM OLD.client_owner_name THEN
    RAISE EXCEPTION 'sales_order_drafts.client_owner_name is immutable after create';
  END IF;
  IF NEW.order_creator_id IS DISTINCT FROM OLD.order_creator_id THEN
    RAISE EXCEPTION 'sales_order_drafts.order_creator_id is immutable after create';
  END IF;
  IF NEW.order_creator_name IS DISTINCT FROM OLD.order_creator_name THEN
    RAISE EXCEPTION 'sales_order_drafts.order_creator_name is immutable after create';
  END IF;
  IF NEW.order_handler_id IS DISTINCT FROM OLD.order_handler_id THEN
    RAISE EXCEPTION 'sales_order_drafts.order_handler_id is immutable after create';
  END IF;
  IF NEW.order_handler_name IS DISTINCT FROM OLD.order_handler_name THEN
    RAISE EXCEPTION 'sales_order_drafts.order_handler_name is immutable after create';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_sales_order_draft_immutable_fields"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_notification_v1"("p_source_application" "text", "p_event_type" "text", "p_channel" "text", "p_message_body" "text", "p_idempotency_key" "text", "p_recipient_email" "text" DEFAULT NULL::"text", "p_recipient_phone" "text" DEFAULT NULL::"text", "p_priority" "text" DEFAULT 'normal'::"text", "p_event_id" "uuid" DEFAULT NULL::"uuid", "p_max_attempts" integer DEFAULT 5, "p_next_attempt_at" timestamp with time zone DEFAULT "now"()) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_id uuid; v_existing public.notification_outbox%rowtype;
begin
  if auth.role() <> 'service_role' then if auth.uid() is null or not public.is_internal_staff(auth.uid()) then raise exception 'internal staff or service role required'; end if; end if;
  if nullif(btrim(p_source_application), '') is null or nullif(btrim(p_event_type), '') is null or nullif(btrim(p_channel), '') is null or nullif(btrim(p_message_body), '') is null or nullif(btrim(p_idempotency_key), '') is null then raise exception 'source_application, event_type, channel, message_body and idempotency_key are required'; end if;
  if p_channel not in ('email','whatsapp','sms','push') then raise exception 'unsupported notification channel'; end if;
  if p_channel = 'email' and nullif(btrim(p_recipient_email), '') is null then raise exception 'email recipient required'; end if;
  if p_channel in ('whatsapp','sms') and nullif(btrim(p_recipient_phone), '') is null then raise exception 'phone recipient required'; end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then raise exception 'max_attempts must be between 1 and 20'; end if;
  select * into v_existing from public.notification_outbox where source_application=p_source_application and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.event_type is distinct from p_event_type or v_existing.channel is distinct from p_channel or v_existing.message_body is distinct from p_message_body or v_existing.recipient_email is distinct from p_recipient_email or v_existing.recipient_phone is distinct from p_recipient_phone then raise exception 'idempotency key conflict'; end if;
    return v_existing.id;
  end if;
  begin
    insert into public.notification_outbox(source_application,event_type,channel,message_body,idempotency_key,recipient_email,recipient_phone,priority,event_id,max_attempts,next_attempt_at,status,attempt_count,updated_at)
    values(p_source_application,p_event_type,p_channel,p_message_body,p_idempotency_key,p_recipient_email,p_recipient_phone,coalesce(p_priority,'normal'),p_event_id,p_max_attempts,coalesce(p_next_attempt_at,now()),'pending',0,now()) returning id into v_id;
    return v_id;
  exception when unique_violation then
    select * into v_existing from public.notification_outbox where source_application=p_source_application and idempotency_key=p_idempotency_key;
    if not found or v_existing.event_type is distinct from p_event_type or v_existing.channel is distinct from p_channel or v_existing.message_body is distinct from p_message_body or v_existing.recipient_email is distinct from p_recipient_email or v_existing.recipient_phone is distinct from p_recipient_phone then raise exception 'idempotency key conflict'; end if;
    return v_existing.id;
  end;
end; $$;


ALTER FUNCTION "public"."enqueue_notification_v1"("p_source_application" "text", "p_event_type" "text", "p_channel" "text", "p_message_body" "text", "p_idempotency_key" "text", "p_recipient_email" "text", "p_recipient_phone" "text", "p_priority" "text", "p_event_id" "uuid", "p_max_attempts" integer, "p_next_attempt_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fail_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_error" "text", "p_retry_delay_seconds" integer DEFAULT NULL::integer) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_row public.notification_outbox%rowtype;
  v_status text;
  v_delay integer;
  v_dead_letter_enabled boolean;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  select * into v_row
  from public.notification_outbox
  where id = p_notification_id
    and status = 'processing'
    and locked_by = p_worker_id
  for update;

  if not found then
    raise exception 'notification lease not owned';
  end if;

  select dead_letter_enabled into v_dead_letter_enabled
  from public.retry_policies
  where policy_key = 'notification.delivery.default' and is_active;

  if v_row.attempt_count >= v_row.max_attempts then
    v_status := 'failed';
  else
    v_status := 'retry';
    v_delay := coalesce(
      p_retry_delay_seconds,
      public.calculate_retry_delay_v1(
        'notification.delivery.default',
        v_row.attempt_count,
        coalesce(v_row.idempotency_key, v_row.id::text)
      )
    );
  end if;

  update public.notification_outbox
  set status = v_status,
      next_attempt_at = case when v_status = 'retry' then now() + make_interval(secs => greatest(v_delay, 0)) else next_attempt_at end,
      error_log = left(coalesce(p_error, 'unknown delivery error'), 4000),
      locked_at = null,
      locked_by = null,
      updated_at = now()
  where id = p_notification_id;

  if v_status = 'failed' and coalesce(v_dead_letter_enabled, true) then
    perform public.record_dead_letter_v1(
      v_row.source_application,
      'notification_delivery',
      'notification_outbox',
      v_row.id::text,
      'notification.delivery.default',
      v_row.attempt_count,
      coalesce(p_error, 'unknown delivery error'),
      null,
      v_row.idempotency_key,
      jsonb_build_object(
        'event_type', v_row.event_type,
        'channel', v_row.channel,
        'priority', v_row.priority,
        'provider_message_id', v_row.provider_message_id
      )
    );
  end if;

  return v_status;
end;
$$;


ALTER FUNCTION "public"."fail_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_error" "text", "p_retry_delay_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finance_review_evidence_immutable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RAISE EXCEPTION 'finance_review_evidence is append-only';
END;
$$;


ALTER FUNCTION "public"."finance_review_evidence_immutable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
DECLARE
  next_serial integer;
  generated_sku text;
BEGIN
  SELECT COALESCE(MAX(NULLIF(regexp_replace(sku, '^.*-([0-9]+)$', '\1'), sku)::integer), 0) + 1
  INTO next_serial
  FROM public.products
  WHERE sku LIKE 'OAS-' || _division_code || '-' || _category_code || '-' || _subcategory_code || '-' || _packaging_code || '-%';

  generated_sku :=
    'OAS-' ||
    _division_code || '-' ||
    _category_code || '-' ||
    _subcategory_code || '-' ||
    _packaging_code || '-' ||
    LPAD(next_serial::text, 4, '0');

  RETURN generated_sku;
END;
$_$;


ALTER FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_order_tracking_token"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.tracking_token IS NULL THEN
    NEW.tracking_token := encode(gen_random_bytes(16), 'hex');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_order_tracking_token"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_user_roles"() RETURNS "text"[]
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.get_my_role_keys();
$$;


ALTER FUNCTION "public"."get_current_user_roles"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_role_keys"() RETURNS "text"[]
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  with role_keys as (
    select lower(r.role_key) as role_key
    from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = auth.uid()
      and coalesce(r.is_active, true) = true

    union

    select lower(u.role) as role_key
    from public.users u
    where u.id = auth.uid()
      and u.role is not null

    union

    select lower(p.role) as role_key
    from public.profiles p
    where p.id = auth.uid()
      and p.role is not null
  )
  select coalesce(array_agg(distinct role_key), array[]::text[])
  from role_keys
  where role_key is not null;
$$;


ALTER FUNCTION "public"."get_my_role_keys"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_price"("_product_id" "uuid", "_customer_type" "text" DEFAULT 'b2b_buyer'::"text") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  SELECT CASE UPPER(TRIM(_customer_type))
    -- Our own stores and master distributors
    WHEN 'SPECIAL_BUYER'    THEN COALESCE(price_special, price_b2b, price_per_kg)
    -- Large distributors and mega buyers
    WHEN 'WHOLESALE_BUYER'  THEN COALESCE(price_wholesale, price_b2b, price_per_kg)
    -- Hotels, restaurants, cafes
    WHEN 'HORECA_BUYER'     THEN COALESCE(price_horeca, price_b2b, price_per_kg)
    -- Export buyers (INR equivalent with export overhead)
    WHEN 'EXPORT_BUYER'     THEN COALESCE(
                                  ROUND(price_b2b * 1.12, 0),
                                  ROUND(price_per_kg * 1.12, 0)
                                )
    -- Standard B2B buyers (catalogue price)
    WHEN 'B2B_BUYER'        THEN COALESCE(price_b2b, price_per_kg)
    WHEN 'CUSTOMER_USER'    THEN COALESCE(price_b2b, price_per_kg)
    WHEN 'CLIENT'           THEN COALESCE(price_b2b, price_per_kg)
    -- Bulk buyers (MRP - 20%)
    WHEN 'BULK_BUYER'       THEN COALESCE(price_bulk, price_b2b, price_per_kg)
    -- Default: B2B catalogue price
    ELSE COALESCE(price_b2b, price_per_kg, base_price, 0)
  END
  FROM public.products
  WHERE id = _product_id
$$;


ALTER FUNCTION "public"."get_product_price"("_product_id" "uuid", "_customer_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_price_usd"("_product_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  SELECT ROUND(
    (get_product_price(_product_id, 'EXPORT_BUYER')) /
    (SELECT exchange_rate FROM public.exchange_rates
     WHERE base_currency = 'USD' AND target_currency = 'INR'
     LIMIT 1),
    2
  )
$$;


ALTER FUNCTION "public"."get_product_price_usd"("_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"("_user_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(
    (
      SELECT upper(r.role_key)
      FROM public.user_role_map urm
      JOIN public.roles r ON r.id = urm.role_id
      WHERE urm.user_id = _user_id
      ORDER BY
        CASE upper(r.role_key)
          WHEN 'SUPER_ADMIN' THEN 1
          WHEN 'ADMIN' THEN 2
          WHEN 'FINANCE_HEAD' THEN 3
          WHEN 'OPERATIONS_MANAGER' THEN 4
          WHEN 'PRODUCTION_MANAGER' THEN 5
          WHEN 'FINANCE_EXEC' THEN 6
          WHEN 'DISPATCH_MANAGER' THEN 7
          WHEN 'STORE_INCHARGE' THEN 8
          WHEN 'SUPPORT_EXECUTIVE' THEN 9
          WHEN 'SALES_EXECUTIVE' THEN 10
          ELSE 99
        END
      LIMIT 1
    ),
    (SELECT upper(role) FROM public.users WHERE id = _user_id LIMIT 1)
  )
$$;


ALTER FUNCTION "public"."get_user_role"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_companies_is_frozen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.is_frozen IS NOT DISTINCT FROM OLD.is_frozen THEN
    RETURN NEW;
  END IF;
  IF COALESCE(current_setting('app.system_credit_op', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'is_frozen is system-managed. Manual override disabled (automated credit governance).';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."guard_companies_is_frozen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_is_frozen_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.is_frozen IS DISTINCT FROM OLD.is_frozen THEN
    IF NOT public.is_internal_staff(auth.uid()) THEN
      RAISE EXCEPTION 'is_frozen is system-managed. Use manual_unlock_credit RPC or month-end lock job.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."guard_is_frozen_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_credit_payment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  comp record;
  cumulative_rescue numeric;
  month_end timestamptz;
BEGIN
  IF NEW.payment_type IS DISTINCT FROM 'rescue' THEN
    RETURN NEW;
  END IF;

  SELECT id, is_frozen, total_outstanding INTO comp
  FROM public.companies WHERE id = NEW.company_id FOR UPDATE;

  IF NOT FOUND OR NOT comp.is_frozen THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO cumulative_rescue
  FROM public.order_payments
  WHERE company_id = NEW.company_id
    AND payment_type = 'rescue'
    AND created_at >= COALESCE((SELECT rescue_payment_date FROM public.companies WHERE id = NEW.company_id), '1970-01-01'::timestamptz);

  IF cumulative_rescue >= (comp.total_outstanding * 0.70) THEN
    month_end := (date_trunc('month', now()) + interval '1 month' - interval '1 second');

    PERFORM set_config('app.system_credit_op', 'on', true);
    UPDATE public.companies
    SET is_frozen = false,
        rescue_payment_date = COALESCE(rescue_payment_date, now()),
        settlement_deadline = month_end
    WHERE id = NEW.company_id;
    PERFORM set_config('app.system_credit_op', 'off', true);

    INSERT INTO public.audit_logs (
      action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
    ) VALUES (
      'CREDIT_UNFREEZE_AUTO', 'credit_governance', 'companies', NEW.company_id::text, NULL,
      'Automated unlock: 70% rescue threshold reached',
      jsonb_build_object(
        'transaction_id', NEW.id,
        'reference_no', NEW.reference_no,
        'rescue_amount', NEW.amount,
        'cumulative_rescue', cumulative_rescue,
        'outstanding_at_unlock', comp.total_outstanding,
        'settlement_deadline', month_end
      ),
      'high'
    );

    INSERT INTO public.credit_rescue_events (
      company_id, event_type, amount, outstanding_at_event, notes, actor_id
    ) VALUES (
      NEW.company_id, 'auto_unlock', NEW.amount, comp.total_outstanding,
      'Auto-unlock via payment ' || NEW.id::text, NULL
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_credit_payment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  BEGIN
    INSERT INTO public.users (id, email, role)
    VALUES (new.id, new.email, NULL)
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Skipping public profile creation due to strict table rules.';
  END;

  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_active_company_membership"("p_user_id" "uuid", "p_company_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  select (p_user_id = auth.uid() or auth.role() = 'service_role')
    and exists (
      select 1 from public.org_memberships m
      where m.user_id = p_user_id and m.company_id = p_company_id
        and m.status = 'active' and m.valid_from <= now()
        and (m.valid_until is null or m.valid_until > now())
    );
$$;


ALTER FUNCTION "public"."has_active_company_membership"("p_user_id" "uuid", "p_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid" DEFAULT NULL::"uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  with permission_config as (
    select p.requires_step_up
    from public.access_permissions p
    where p.permission_key = p_permission_key and p.is_active
  ),
  global_roles as (
    select r.role_key from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = p_user_id and coalesce(r.is_active, true)
  ),
  scoped_roles as (
    select mr.role_key from public.org_memberships m
    join public.org_membership_roles mr on mr.membership_id = m.id
    where m.user_id = p_user_id and m.status = 'active'
      and m.valid_from <= now() and (m.valid_until is null or m.valid_until > now())
      and (p_company_id is null or m.company_id = p_company_id)
      and (
        p_branch_id is null
        or not exists (select 1 from public.org_membership_branch_scopes s0 where s0.membership_id = m.id)
        or exists (select 1 from public.org_membership_branch_scopes s where s.membership_id = m.id and s.branch_id = p_branch_id)
      )
  ),
  all_roles as (
    select role_key from global_roles union select role_key from scoped_roles
  ),
  decisions as (
    select g.effect from all_roles ar
    join public.role_permission_grants g on g.role_key = ar.role_key
    where g.permission_key = p_permission_key
  )
  select case
    when not (p_user_id = auth.uid() or auth.role() = 'service_role') then false
    when not exists (select 1 from permission_config) then false
    when coalesce((select requires_step_up from permission_config), false)
      and not public.has_step_up_auth() then false
    when exists (select 1 from decisions where effect = 'deny') then false
    when exists (select 1 from global_roles where role_key = 'super_admin') then true
    else exists (select 1 from decisions where effect = 'allow')
  end;
$$;


ALTER FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid", "p_branch_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid", "p_branch_id" "uuid") IS 'Deny-overrides capability evaluation across existing global roles and new company-scoped membership roles.';



CREATE OR REPLACE FUNCTION "public"."has_catalogue_permission"("p_permission_key" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select
    case
      when auth.uid() is null then false
      when 'super_admin' = any(public.get_my_role_keys()) then true
      else exists (
        select 1
        from public.permissions p
        join public.role_permission_map rpm on rpm.permission_id = p.id
        join public.roles r on r.id = rpm.role_id
        where p.permission_key = p_permission_key
          and lower(r.role_key) = any(public.get_my_role_keys())
          and coalesce(r.is_active, true) = true
      )
    end;
$$;


ALTER FUNCTION "public"."has_catalogue_permission"("p_permission_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_step_up_auth"() RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'auth'
    AS $$
  select auth.role() = 'service_role'
    or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;


ALTER FUNCTION "public"."has_step_up_auth"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."has_step_up_auth"() IS 'Returns true for Supabase AAL2 sessions or service-role execution.';



CREATE OR REPLACE FUNCTION "public"."increment_announcement_counter"("ann_id" "uuid", "counter_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF counter_name = 'view' THEN
    UPDATE premium_announcements SET view_count = view_count + 1 WHERE id = ann_id;
  ELSIF counter_name = 'skip' THEN
    UPDATE premium_announcements SET skip_count = skip_count + 1 WHERE id = ann_id;
  ELSIF counter_name = 'completion' THEN
    UPDATE premium_announcements SET completion_count = completion_count + 1 WHERE id = ann_id;
  END IF;
END;
$$;


ALTER FUNCTION "public"."increment_announcement_counter"("ann_id" "uuid", "counter_name" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_inbound_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider_message_id" "text",
    "sender_phone" "text" NOT NULL,
    "sender_name" "text",
    "message_body" "text" NOT NULL,
    "message_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "raw_payload" "jsonb",
    "resolver_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "resolver_result_json" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_inbound_messages_resolver_status_check" CHECK (("resolver_status" = ANY (ARRAY['pending'::"text", 'resolved'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."whatsapp_inbound_messages" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_inbound_messages" IS 'Phase 2C read-only inbound WhatsApp messages. Resolver output stored at ingest; no order side effects.';



CREATE OR REPLACE FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text" DEFAULT 'text'::"text", "_received_at" timestamp with time zone DEFAULT "now"(), "_raw_payload" "jsonb" DEFAULT NULL::"jsonb", "_resolver_status" "text" DEFAULT 'pending'::"text", "_resolver_result_json" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."whatsapp_inbound_messages"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  existing public.whatsapp_inbound_messages;
  inserted public.whatsapp_inbound_messages;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to ingest whatsapp messages';
  END IF;

  IF _sender_phone IS NULL OR btrim(_sender_phone) = '' THEN
    RAISE EXCEPTION 'sender_phone is required';
  END IF;

  IF _message_body IS NULL OR btrim(_message_body) = '' THEN
    RAISE EXCEPTION 'message_body is required';
  END IF;

  IF _provider_message_id IS NOT NULL AND btrim(_provider_message_id) <> '' THEN
    SELECT * INTO existing
    FROM public.whatsapp_inbound_messages
    WHERE provider_message_id = _provider_message_id
    LIMIT 1;

    IF FOUND THEN
      RETURN existing;
    END IF;
  END IF;

  INSERT INTO public.whatsapp_inbound_messages (
    provider_message_id,
    sender_phone,
    sender_name,
    message_body,
    message_type,
    received_at,
    raw_payload,
    resolver_status,
    resolver_result_json
  )
  VALUES (
    NULLIF(btrim(_provider_message_id), ''),
    btrim(_sender_phone),
    NULLIF(btrim(_sender_name), ''),
    btrim(_message_body),
    COALESCE(NULLIF(btrim(_message_type), ''), 'text'),
    COALESCE(_received_at, now()),
    _raw_payload,
    COALESCE(NULLIF(btrim(_resolver_status), ''), 'pending'),
    _resolver_result_json
  )
  RETURNING * INTO inserted;

  RETURN inserted;
END;
$$;


ALTER FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text", "_received_at" timestamp with time zone, "_raw_payload" "jsonb", "_resolver_status" "text", "_resolver_result_json" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text", "_received_at" timestamp with time zone, "_raw_payload" "jsonb", "_resolver_status" "text", "_resolver_result_json" "jsonb") IS 'Phase 2C internal ingestion. Idempotent on provider_message_id. Team members or service role only.';



CREATE OR REPLACE FUNCTION "public"."is_account_manager"("_user_id" "uuid", "_company_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.companies
    WHERE id = _company_id
      AND account_manager_id = _user_id
  )
$$;


ALTER FUNCTION "public"."is_account_manager"("_user_id" "uuid", "_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND role IN ('super_admin', 'admin')
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_catalogue_reviewer"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.has_catalogue_permission('catalogue.approvals.review');
$$;


ALTER FUNCTION "public"."is_catalogue_reviewer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_internal_staff"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = _user_id
      AND upper(role) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
        'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
        'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
        'STORE_INCHARGE', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD', 'SECURITY_CONTROL',
        'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
      ])
  )
$$;


ALTER FUNCTION "public"."is_internal_staff"("_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_internal_staff"("_user_id" "uuid") IS 'True when user is internal staff. Includes DISPATCH_HEAD (24I) for inventory governance RLS.';



CREATE OR REPLACE FUNCTION "public"."is_staff_role"("_role" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT upper(coalesce(_role, '')) = ANY (
    ARRAY[
      -- Admin
      'SUPER_ADMIN', 'ADMIN', 'OWNER',
      -- Finance
      'FINANCE_HEAD', 'FINANCE_EXEC', 'FINANCE_AUDITOR',
      -- Operations
      'OPERATIONS_MANAGER',
      -- Production managers (HOD level)
      'PRODUCTION_MANAGER',
      'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE',
      'HOD_DRAGEES', 'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
      -- Production floor TV accounts
      'PROD_ARABIC_SWEETS', 'PROD_CHOCOLATE', 'PROD_DRAGEES',
      'PROD_FUSION', 'PROD_BAKERY', 'PROD_NUTS',
      -- TV display accounts (read-only wall screens)
      'TV_DISPLAY', 'TV_ASSEMBLY', 'TV_READY', 'TV_DRAGEES',
      -- Store / Warehouse
      'STORE_INCHARGE', 'STORE_3RD_PARTY',
      'STORE_READY_GOODS', 'RGS_ADMIN',
      -- Dispatch
      'DISPATCH_HEAD', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE',
      -- Packing / Assembly
      'ASSEMBLY_MANAGER', 'PACKING_SUPERVISOR',
      -- Sales & Support
      'SALES_EXECUTIVE', 'SUPPORT_EXECUTIVE',
      -- Catalogue
      'CATALOGUE_CONTRIBUTOR',
      -- Security
      'SECURITY_CONTROL', 'GATE_SECURITY',
      -- Legacy
      'STORE_3RD_PARTY', 'HOD_ARABIC'
    ]
  );
$$;


ALTER FUNCTION "public"."is_staff_role"("_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_team_member"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_role_map urm
    INNER JOIN public.roles r ON r.id = urm.role_id
    WHERE urm.user_id = _user_id
      AND COALESCE(r.is_active, true)
      AND r.role_key IN (
        'super_admin',
        'admin',
        'owner',
        'catalogue_admin',
        'catalogue_manager',
        'operations',
        'sales'
      )
  );
$$;


ALTER FUNCTION "public"."is_team_member"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT upper(public.get_user_role(_user_id)) = ANY (ARRAY[
    'SUPER_ADMIN'::text,
    'ADMIN'::text,
    'SUPPORT_EXECUTIVE'::text
  ])
$$;


ALTER FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") IS 'Stage-1 read-only operator inbox: grants SELECT on whatsapp_message_packets, whatsapp_contacts, and packet-linked whatsapp_messages. No write authority.';



CREATE OR REPLACE FUNCTION "public"."link_buyer_on_application_approval"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  resolved_company_id uuid;
BEGIN
  IF NEW.status <> 'approved' OR NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  SELECT id INTO resolved_company_id
  FROM public.companies
  WHERE business_name = NEW.business_name
  LIMIT 1;

  IF resolved_company_id IS NULL THEN
    INSERT INTO public.companies (business_name, gst_number, phone, registered_address, status)
    VALUES (NEW.business_name, NEW.gst_number, NEW.contact_phone, NEW.registered_address, 'active')
    RETURNING id INTO resolved_company_id;
  END IF;

  INSERT INTO public.users (id, email, role, company_id)
  VALUES (NEW.user_id, NEW.contact_email, 'b2b_buyer', resolved_company_id)
  ON CONFLICT (id) DO UPDATE
    SET company_id = COALESCE(public.users.company_id, EXCLUDED.company_id),
        role = COALESCE(NULLIF(public.users.role, ''), EXCLUDED.role);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."link_buyer_on_application_approval"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_cart_failure"("_company_id" "uuid", "_error_message" "text", "_error_code" "text" DEFAULT NULL::"text", "_context" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.audit_logs (
    actor_id, module_name, action_type, entity_name, entity_id,
    reason, new_value, risk_level
  ) VALUES (
    auth.uid(),
    'cart',
    'create_draft_order_failed',
    'orders',
    COALESCE(_company_id::text,'(null)'),
    _error_message,
    jsonb_build_object('error_code', _error_code, 'context', _context),
    'high'
  );
END;
$$;


ALTER FUNCTION "public"."log_cart_failure"("_company_id" "uuid", "_error_message" "text", "_error_code" "text", "_context" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_admin_new_b2b_application"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  admin_record RECORD;
BEGIN
  -- Insert a notification for each admin/super_admin user
  FOR admin_record IN
    SELECT id FROM public.users
    WHERE upper(role) IN ('ADMIN', 'SUPER_ADMIN')
    LIMIT 20
  LOOP
    INSERT INTO public.notifications (
      user_id,
      type,
      message,
      is_read
    ) VALUES (
      admin_record.id,
      'new_application',
      '🆕 New B2B Application: ' || COALESCE(NEW.business_name, 'Unknown') || ' — Contact: ' || COALESCE(NEW.contact_person, NEW.contact_email, 'N/A'),
      false
    );
  END LOOP;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_admin_new_b2b_application"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ols_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."ols_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_inventory_movement_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'inventory_movements are append-only (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "public"."prevent_inventory_movement_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_operational_event_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'operational_events are append-only (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "public"."prevent_operational_event_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_operational_scan_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'operational_scan_records are append-only (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "public"."prevent_operational_scan_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_order_status_regression"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  locked_statuses text[] := ARRAY['approved','awaiting_advance','in_production','manufacturing','assembly','assembled','packing','partial_ready','packed_ready','awaiting_final_payment','awaiting_payment','cleared_for_dispatch','dispatched','in_transit','delivered','closed'];
BEGIN
  IF OLD.status = ANY(locked_statuses) AND NEW.status IN ('draft','cart') THEN
    NEW.status := OLD.status;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_order_status_regression"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_profile_privilege_escalation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF public.is_internal_staff(auth.uid()) THEN
    RETURN NEW;
  END IF;

  -- Non-staff cannot change sensitive fields
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    NEW.role := OLD.role;
  END IF;
  IF to_jsonb(NEW) ? 'is_approved' AND (to_jsonb(NEW)->>'is_approved') IS DISTINCT FROM (to_jsonb(OLD)->>'is_approved') THEN
    NEW := jsonb_populate_record(NEW, jsonb_build_object('is_approved', to_jsonb(OLD)->'is_approved'));
  END IF;
  IF to_jsonb(NEW) ? 'status' AND (to_jsonb(NEW)->>'status') IS DISTINCT FROM (to_jsonb(OLD)->>'status') THEN
    NEW := jsonb_populate_record(NEW, jsonb_build_object('status', to_jsonb(OLD)->'status'));
  END IF;
  IF to_jsonb(NEW) ? 'price_tier' AND (to_jsonb(NEW)->>'price_tier') IS DISTINCT FROM (to_jsonb(OLD)->>'price_tier') THEN
    NEW := jsonb_populate_record(NEW, jsonb_build_object('price_tier', to_jsonb(OLD)->'price_tier'));
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_profile_privilege_escalation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_stock_consumption_lineage_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'stock_consumption_lineage is append-only (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;


ALTER FUNCTION "public"."prevent_stock_consumption_lineage_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."published_products_v1"() RETURNS TABLE("product_id" "uuid", "sku" "text", "product_name" "text", "short_description" "text", "long_description" "text", "category" "text", "subcategory" "text", "hero_image_url" "text", "pack_size" "text", "storage_type" "text", "shelf_life" "text", "shelf_life_days" integer, "dietary_tags" "text"[], "allergen_warnings" "text", "primary_uom" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  select
    p.id as product_id,
    p.sku,
    coalesce(nullif(btrim(p.product_name), ''), p.name) as product_name,
    nullif(btrim(p.short_description), '') as short_description,
    nullif(btrim(p.description), '') as long_description,
    p.category,
    coalesce(nullif(btrim(p.subcategory), ''), nullif(btrim(p.sub_category), '')) as subcategory,
    coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), '')) as hero_image_url,
    p.pack_size,
    p.storage_type,
    p.shelf_life,
    p.shelf_life_days,
    p.dietary_tags,
    p.allergen_warnings,
    coalesce(nullif(btrim(p.primary_uom), ''), nullif(btrim(p.uom), '')) as primary_uom,
    p.created_at
  from public.products p
  where p.is_active is true
    and p.visible_in_catalog is true
    and p.is_catalogue_ready is true
    and nullif(btrim(p.sku), '') is not null
    and coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), '')) is not null
  order by coalesce(nullif(btrim(p.product_name), ''), p.name), p.id;
$$;


ALTER FUNCTION "public"."published_products_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."published_products_v1"() IS 'Customer-safe product catalogue projection v1. Returns only active, visible, catalogue-ready products and excludes pricing, cost, MOQ, operational and draft-only fields.';



CREATE OR REPLACE FUNCTION "public"."recalculate_erp_order_financials"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  calc_subtotal numeric := 0;
  calc_total numeric := 0;
BEGIN
  SELECT COALESCE(
    SUM(
      COALESCE(oi.quantity, 0) * COALESCE(
        p.price_per_kg,
        p.base_price,
        p.price_b2b,
        p.price_wholesale,
        p.wholesale_price,
        0
      )
    ),
    0
  )
  INTO calc_subtotal
  FROM public.order_items oi
  JOIN public.products p ON p.id = oi.product_id
  WHERE oi.order_id = NEW.order_id;

  calc_total := calc_subtotal * 1.18;

  UPDATE public.orders
  SET sales_order_value = calc_total,
      advance_required = calc_total * 0.5
  WHERE id = NEW.order_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."recalculate_erp_order_financials"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_dead_letter_v1"("p_source_application" "text", "p_workload_type" "text", "p_source_table" "text", "p_source_record_id" "text", "p_policy_key" "text", "p_attempt_count" integer, "p_error_message" "text", "p_error_code" "text" DEFAULT NULL::"text", "p_idempotency_key" "text" DEFAULT NULL::"text", "p_context" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_id uuid;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  if nullif(btrim(p_source_application), '') is null
     or nullif(btrim(p_workload_type), '') is null
     or nullif(btrim(p_source_table), '') is null
     or nullif(btrim(p_source_record_id), '') is null
     or nullif(btrim(p_error_message), '') is null then
    raise exception 'source, workload, table, record and error message are required';
  end if;

  insert into public.dead_letter_entries (
    source_application, workload_type, source_table, source_record_id,
    policy_key, idempotency_key, attempt_count, error_code,
    error_message, context, first_failed_at, last_failed_at, updated_at
  ) values (
    p_source_application, p_workload_type, p_source_table, p_source_record_id,
    p_policy_key, p_idempotency_key, p_attempt_count, p_error_code,
    left(p_error_message, 4000), coalesce(p_context, '{}'::jsonb), now(), now(), now()
  )
  on conflict (source_table, source_record_id) where status = 'open'
  do update set
    attempt_count = greatest(public.dead_letter_entries.attempt_count, excluded.attempt_count),
    error_code = excluded.error_code,
    error_message = excluded.error_message,
    context = excluded.context,
    last_failed_at = now(),
    updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;


ALTER FUNCTION "public"."record_dead_letter_v1"("p_source_application" "text", "p_workload_type" "text", "p_source_table" "text", "p_source_record_id" "text", "p_policy_key" "text", "p_attempt_count" integer, "p_error_message" "text", "p_error_code" "text", "p_idempotency_key" "text", "p_context" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_operator_decisions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_message_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "sku" "text",
    "product_name" "text",
    "confidence_band" "text",
    "whatsapp_sales_order_draft_id" "uuid",
    "decided_by" "uuid" NOT NULL,
    "decided_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_operator_decisions_action_check" CHECK (("action" = ANY (ARRAY['confirm'::"text", 'reject'::"text", 'select_alternative'::"text"])))
);


ALTER TABLE "public"."whatsapp_operator_decisions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") RETURNS "public"."whatsapp_operator_decisions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  inserted public.whatsapp_operator_decisions;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to record operator decisions';
  END IF;

  IF _action NOT IN ('reject', 'select_alternative') THEN
    RAISE EXCEPTION 'invalid action for this RPC';
  END IF;

  INSERT INTO public.whatsapp_operator_decisions (
    source_message_id,
    action,
    sku,
    product_name,
    confidence_band,
    decided_by
  )
  VALUES (
    _source_message_id,
    _action,
    NULLIF(btrim(_sku), ''),
    NULLIF(btrim(_product_name), ''),
    _confidence_band,
    auth.uid()
  )
  RETURNING * INTO inserted;

  RETURN inserted;
END;
$$;


ALTER FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") IS 'Phase 2E durable reject/alternative operator audit. No order side effects.';



CREATE OR REPLACE FUNCTION "public"."reject_catalogue_alias_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_alias_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_alias_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_bom_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_bom_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_bom_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  v_before jsonb;
  v_after jsonb;
  v_status text;
  v_allowed text[] := array[
    'catalogue_product_drafts',
    'catalogue_media_submissions',
    'catalogue_alias_drafts',
    'catalogue_bom_drafts',
    'catalogue_moq_drafts',
    'catalogue_pricing_drafts',
    'catalogue_tag_drafts'
  ];
begin
  if not public.is_catalogue_reviewer() then
    raise exception 'Catalogue reviewer permission required';
  end if;

  if not (p_draft_table = any(v_allowed)) then
    raise exception 'Unsupported draft table: %', p_draft_table;
  end if;

  execute format('select to_jsonb(t) from public.%I t where id = $1 for update', p_draft_table)
    using p_draft_id
    into v_before;

  if v_before is null then
    raise exception 'Draft not found: %.%', p_draft_table, p_draft_id;
  end if;

  v_status := v_before ->> 'status';

  if v_status <> 'pending_approval' then
    raise exception 'Only pending_approval drafts can be rejected. Current status: %', v_status;
  end if;

  execute format(
    'update public.%I
       set status = ''rejected'',
           reviewed_by = auth.uid(),
           reviewed_at = now(),
           review_notes = $2,
           updated_at = now()
     where id = $1',
    p_draft_table
  )
  using p_draft_id, p_reason;

  execute format('select to_jsonb(t) from public.%I t where id = $1', p_draft_table)
    using p_draft_id
    into v_after;

  insert into public.catalogue_approval_audit (
    draft_table,
    draft_id,
    action,
    performed_by,
    payload_snapshot,
    before_snapshot,
    after_snapshot,
    notes
  )
  values (
    p_draft_table,
    p_draft_id,
    'rejected',
    auth.uid(),
    v_before -> 'payload',
    v_before,
    v_after,
    p_reason
  );

  return jsonb_build_object(
    'ok', true,
    'action', 'rejected',
    'draft_table', p_draft_table,
    'draft_id', p_draft_id
  );
end;
$_$;


ALTER FUNCTION "public"."reject_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_media_submission"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_media_submissions', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_media_submission"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_moq_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_moq_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_moq_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_pricing_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_pricing_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_pricing_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_product_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_product_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_product_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_catalogue_tag_draft"("draft_id" "uuid", "reason" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select public.reject_catalogue_draft_internal('catalogue_tag_drafts', draft_id, reason);
$$;


ALTER FUNCTION "public"."reject_catalogue_tag_draft"("draft_id" "uuid", "reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_status text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to reject sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  IF NULLIF(trim(p_rejection_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Rejection reason is required';
  END IF;

  SELECT d.status
  INTO v_status
  FROM public.sales_order_drafts d
  WHERE d.id = p_draft_id
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Sales order draft not found';
  END IF;

  IF v_status NOT IN ('AI_DRAFT', 'UNDER_REVIEW') THEN
    RAISE EXCEPTION 'Reject not allowed from terminal status %', v_status;
  END IF;

  UPDATE public.sales_order_drafts
  SET
    status = 'REJECTED',
    rejection_reason = trim(p_rejection_reason),
    review_notes = COALESCE(p_review_notes, review_notes),
    updated_by = p_actor_id
  WHERE id = p_draft_id;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    p_draft_id,
    'REJECT',
    v_status,
    'REJECTED',
    p_actor_id,
    p_actor_name,
    COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object('rejectionReason', trim(p_rejection_reason))
  );

  RETURN p_draft_id;
END;
$$;


ALTER FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") IS 'Atomically rejects draft with reason and appends audit row.';



CREATE OR REPLACE FUNCTION "public"."resolve_dead_letter_v1"("p_dead_letter_id" "uuid", "p_status" "text", "p_resolution_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if auth.role() <> 'service_role' then
    if auth.uid() is null or public.get_user_role(auth.uid()) not in ('admin','super_admin') then
      raise exception 'administrator or service role required';
    end if;
  end if;

  if p_status not in ('requeued','resolved','discarded') then
    raise exception 'invalid terminal dead-letter status';
  end if;

  update public.dead_letter_entries
  set status = p_status,
      requeued_at = case when p_status = 'requeued' then now() else requeued_at end,
      resolved_at = case when p_status in ('resolved','discarded') then now() else resolved_at end,
      resolved_by = auth.uid(),
      resolution_note = p_resolution_note,
      updated_at = now()
  where id = p_dead_letter_id and status = 'open';

  if not found then
    raise exception 'open dead-letter entry not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."resolve_dead_letter_v1"("p_dead_letter_id" "uuid", "p_status" "text", "p_resolution_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_order_qty_to_kg"("_product_id" "uuid", "_qty" numeric, "_input_uom" "text") RETURNS TABLE("qty_in_kg" numeric, "qty_in_pcs" numeric, "b2b_price_total" numeric, "input_was" "text", "converted_to" "text", "confidence" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  p record;
  uom_lower text := LOWER(TRIM(_input_uom));
  kg_qty numeric := 0;
  pcs_qty numeric := 0;
  conf text := 'HIGH';
BEGIN
  SELECT
    weight_per_pc_grams,
    pcs_per_kg,
    kg_per_primary_pack,
    kg_per_master_carton,
    packs_per_master_carton,
    price_per_kg,
    price_b2b
  INTO p
  FROM public.products
  WHERE id = _product_id AND is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, _input_uom, 'error', 'PRODUCT_NOT_FOUND';
    RETURN;
  END IF;

  -- Resolve input UOM to kg
  CASE uom_lower
    -- Direct kg inputs
    WHEN 'kg', 'kgs', 'kilo', 'kilos', 'kilogram', 'kilograms' THEN
      kg_qty := _qty;
      conf := 'HIGH';

    -- Gram inputs
    WHEN 'g', 'gm', 'gms', 'gram', 'grams' THEN
      kg_qty := _qty / 1000.0;
      conf := 'HIGH';

    -- Piece inputs
    WHEN 'pc', 'pcs', 'piece', 'pieces', 'piec', 'piecs', 'nos', 'no', 'unit', 'units', 'qty' THEN
      IF p.weight_per_pc_grams > 0 THEN
        kg_qty := (_qty * p.weight_per_pc_grams) / 1000.0;
        conf := 'HIGH';
      ELSE
        kg_qty := _qty / 40.0; -- fallback: assume 25g/pc
        conf := 'LOW';
      END IF;

    -- Box / pack / tray (primary pack)
    WHEN 'box', 'boxes', 'pack', 'packs', 'packet', 'packets',
         'tray', 'trays', 'jar', 'jars', 'tin', 'tins' THEN
      IF p.kg_per_primary_pack > 0 THEN
        kg_qty := _qty * p.kg_per_primary_pack;
        conf := 'HIGH';
      ELSIF p.weight_per_pc_grams > 0 THEN
        -- Estimate: assume ~30 pcs per box
        kg_qty := _qty * 30 * p.weight_per_pc_grams / 1000.0;
        conf := 'MEDIUM';
      END IF;

    -- Carton / master carton
    WHEN 'carton', 'cartons', 'master_carton', 'master carton',
         'mc', 'ctn', 'ctns', 'case', 'cases' THEN
      IF p.kg_per_master_carton > 0 THEN
        kg_qty := _qty * p.kg_per_master_carton;
        conf := 'HIGH';
      ELSIF p.kg_per_primary_pack > 0 AND p.packs_per_master_carton > 0 THEN
        kg_qty := _qty * p.kg_per_primary_pack * p.packs_per_master_carton;
        conf := 'MEDIUM';
      END IF;

    ELSE
      -- Unknown UOM — assume kg as fallback
      kg_qty := _qty;
      conf := 'LOW';
  END CASE;

  -- Round to 2 decimal places
  kg_qty := ROUND(kg_qty, 2);

  -- Calculate pcs from kg
  IF p.weight_per_pc_grams > 0 THEN
    pcs_qty := ROUND((kg_qty * 1000.0) / p.weight_per_pc_grams, 0);
  END IF;

  RETURN QUERY SELECT
    kg_qty,
    pcs_qty,
    ROUND(kg_qty * COALESCE(p.price_per_kg, p.price_b2b, 0), 0),
    _input_uom,
    'kg',
    conf;
END;
$$;


ALTER FUNCTION "public"."resolve_order_qty_to_kg"("_product_id" "uuid", "_qty" numeric, "_input_uom" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_order_financials"("_order_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  calc_subtotal numeric := 0;
  calc_total numeric := 0;
BEGIN
  SELECT COALESCE(
    SUM(
      COALESCE(oi.quantity, 0) * COALESCE(
        p.price_per_kg,
        p.base_price,
        p.price_b2b,
        p.price_wholesale,
        p.wholesale_price,
        0
      )
    ),
    0
  )
  INTO calc_subtotal
  FROM public.order_items oi
  JOIN public.products p ON p.id = oi.product_id
  WHERE oi.order_id = _order_id;

  calc_total := calc_subtotal * 1.18;

  UPDATE public.orders
  SET sales_order_value = calc_total,
      advance_required = calc_total * 0.5
  WHERE id = _order_id;

  RETURN calc_total;
END;
$$;


ALTER FUNCTION "public"."restore_order_financials"("_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_customer_import_validation"("p_batch_id" "uuid") RETURNS TABLE("check_code" "text", "severity" "text", "row_count" bigint, "is_blocking" boolean, "detail" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ BEGIN IF auth.uid() IS NOT NULL AND NOT public.is_internal_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized: customer import validation is restricted to internal staff'; END IF; IF NOT EXISTS (SELECT 1 FROM public.customer_import_batches b WHERE b.id = p_batch_id) THEN RETURN QUERY SELECT 'batch_not_found'::text, 'error'::text, 1::bigint, true, 'Fatal: customer import batch id not found; no further validation checks were run'::text; RETURN; END IF; RETURN QUERY SELECT 'raw_rows_loaded', 'info', COUNT(*), false, 'Rows in customer_import_raw' FROM public.customer_import_raw r WHERE r.batch_id = p_batch_id UNION ALL SELECT 'company_candidates', 'info', COUNT(*), false, 'Rows in customer_import_company_candidates' FROM public.customer_import_company_candidates c WHERE c.batch_id = p_batch_id UNION ALL SELECT 'contact_candidates', 'info', COUNT(*), false, 'Rows in customer_import_contact_candidates' FROM public.customer_import_contact_candidates ct WHERE ct.batch_id = p_batch_id UNION ALL SELECT 'duplicate_gst_in_batch', 'error', COUNT(*), (COUNT(*) > 0), 'Duplicate GST groups within batch' FROM public.v_customer_import_duplicate_gst_in_batch g WHERE g.batch_id = p_batch_id UNION ALL SELECT 'duplicate_phone_any_in_batch', 'error', COUNT(*), (COUNT(*) > 0), 'Duplicate phone groups within batch (company and/or contact rows)' FROM public.v_customer_import_duplicate_phone_any_in_batch p WHERE p.batch_id = p_batch_id UNION ALL SELECT 'duplicate_phone_in_batch', 'info', COUNT(*), false, 'Duplicate company-only phone groups within batch' FROM public.v_customer_import_duplicate_phone_in_batch p WHERE p.batch_id = p_batch_id UNION ALL SELECT 'duplicate_name_in_batch', 'error', COUNT(*), (COUNT(*) > 0), 'Duplicate company name groups within batch' FROM public.v_customer_import_duplicate_name_in_batch n WHERE n.batch_id = p_batch_id UNION ALL SELECT 'duplicate_contact_phone_in_batch', 'info', COUNT(*), false, 'Duplicate contact-only phone groups within batch' FROM public.v_customer_import_duplicate_contact_phone_in_batch p WHERE p.batch_id = p_batch_id UNION ALL SELECT 'orphan_contacts', 'error', COUNT(*), (COUNT(*) > 0), 'Contacts without matching company candidate key' FROM public.v_customer_import_orphan_contacts o WHERE o.batch_id = p_batch_id UNION ALL SELECT 'required_field_gaps', 'error', COUNT(*), (COUNT(*) > 0), 'Company candidates with required field gaps' FROM public.v_customer_import_company_required_gaps g WHERE g.batch_id = p_batch_id AND cardinality(g.gap_codes) > 0 UNION ALL SELECT 'contact_phone_gaps', 'error', COUNT(*), (COUNT(*) > 0), 'Contact candidates with missing or invalid phone' FROM public.v_customer_import_contact_phone_gaps g WHERE g.batch_id = p_batch_id AND cardinality(g.gap_codes) > 0 UNION ALL SELECT 'company_rows_pending_review', 'error', COUNT(*), (COUNT(*) > 0), 'Company candidates with import_action = review' FROM public.customer_import_company_candidates c WHERE c.batch_id = p_batch_id AND c.import_action = 'review' UNION ALL SELECT 'contact_rows_pending_review', 'error', COUNT(*), (COUNT(*) > 0), 'Contact candidates with import_action = review' FROM public.customer_import_contact_candidates ct WHERE ct.batch_id = p_batch_id AND ct.import_action = 'review' UNION ALL SELECT 'gst_conflicts_existing', 'warning', COUNT(*), false, 'Import GST matches different existing company' FROM public.v_customer_import_gst_match_existing m WHERE m.batch_id = p_batch_id AND m.match_outcome = 'conflict_existing_gst' UNION ALL SELECT 'duplicate_review_pending', 'error', COUNT(*), (COUNT(*) > 0), 'Duplicate review rows still pending' FROM public.customer_import_duplicate_review d WHERE d.batch_id = p_batch_id AND d.resolution_status = 'pending' UNION ALL SELECT 'promotion_not_ready', 'error', 1::bigint, true, 'One or more promotion readiness gates failed; see v_customer_import_promotion_readiness' FROM public.v_customer_import_promotion_readiness pr WHERE pr.batch_id = p_batch_id AND pr.safe_for_staging_promotion_review = false; END; $$;


ALTER FUNCTION "public"."run_customer_import_validation"("p_batch_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_month_end_credit_lock"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  c record;
  locked_count int := 0;
BEGIN
  PERFORM set_config('app.system_credit_op', 'on', true);

  FOR c IN
    SELECT id, total_outstanding FROM public.companies
    WHERE payment_terms = 'credit' AND total_outstanding > 0 AND is_frozen = false
  LOOP
    UPDATE public.companies
    SET is_frozen = true, rescue_payment_date = NULL, settlement_deadline = NULL
    WHERE id = c.id;

    INSERT INTO public.audit_logs (
      action_type, module_name, entity_name, entity_id, reason, new_value, risk_level
    ) VALUES (
      'CREDIT_FREEZE_MONTH_END', 'credit_governance', 'companies', c.id::text,
      'Month-end automated freeze: outstanding > 0',
      jsonb_build_object('outstanding', c.total_outstanding, 'locked_at', now()),
      'high'
    );

    INSERT INTO public.credit_rescue_events (
      company_id, event_type, outstanding_at_event, notes
    ) VALUES (c.id, 'month_end_lock', c.total_outstanding, 'Automated month-end lock');

    locked_count := locked_count + 1;
  END LOOP;

  PERFORM set_config('app.system_credit_op', 'off', true);
  RETURN jsonb_build_object('locked', locked_count, 'ran_at', now());
END;
$$;


ALTER FUNCTION "public"."run_month_end_credit_lock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE LEFT(object_path, length(o.id::text) + 1) = o.id::text || '-'
      AND o.company_id IS NOT DISTINCT FROM COALESCE(
        (SELECT u.company_id FROM public.users u WHERE u.id = auth.uid() LIMIT 1),
        (SELECT p.company_id FROM public.profiles p WHERE p.id = auth.uid() LIMIT 1)
      )
  );
$$;


ALTER FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text" DEFAULT NULL::"text", "p_quantity_affected" integer DEFAULT NULL::integer) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'auth'
    AS $$
declare
  new_ticket_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;

  if nullif(btrim(p_issue_type), '') is null then
    raise exception 'issue type is required';
  end if;

  if nullif(btrim(p_description), '') is null or length(btrim(p_description)) < 10 then
    raise exception 'description must contain at least 10 characters';
  end if;

  if length(btrim(p_description)) > 4000 then
    raise exception 'description exceeds 4000 characters';
  end if;

  if p_quantity_affected is not null and p_quantity_affected <= 0 then
    raise exception 'quantity affected must be positive';
  end if;

  insert into public.support_tickets (
    order_id,
    issue_type,
    description,
    product_sku,
    qty_affected,
    status
  ) values (
    p_order_id::text,
    lower(replace(btrim(p_issue_type), ' ', '_')),
    btrim(p_description),
    nullif(btrim(p_product_sku), ''),
    p_quantity_affected,
    'open'
  )
  returning id into new_ticket_id;

  return new_ticket_id;
end;
$$;


ALTER FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text", "p_quantity_affected" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text", "p_quantity_affected" integer) IS 'Creates a support ticket only for an order owned by the authenticated approved company.';



CREATE OR REPLACE FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_status text;
  v_extraction_request_key text;
  v_line jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to submit sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  IF NULLIF(trim(p_expected_extraction_request_key), '') IS NULL THEN
    RAISE EXCEPTION 'Expected extraction request key is required';
  END IF;

  SELECT d.status, d.extraction_request_key
  INTO v_status, v_extraction_request_key
  FROM public.sales_order_drafts d
  WHERE d.id = p_draft_id
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Sales order draft not found';
  END IF;

  IF v_status <> 'AI_DRAFT' THEN
    RAISE EXCEPTION 'Submit for review only allowed from AI_DRAFT, currently %', v_status;
  END IF;

  IF v_extraction_request_key IS DISTINCT FROM trim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'Extraction version mismatch for draft %', p_draft_id;
  END IF;

  UPDATE public.sales_order_drafts
  SET
    operator_final_snapshot = COALESCE(p_operator_final_snapshot, '{}'::jsonb),
    readiness_overall_score = COALESCE(p_readiness_overall_score, 0),
    readiness_dimensions = COALESCE(p_readiness_dimensions, '[]'::jsonb),
    status = 'UNDER_REVIEW',
    updated_by = p_actor_id
  WHERE id = p_draft_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb))
  LOOP
    UPDATE public.sales_order_draft_lines
    SET
      operator_quantity = NULLIF(v_line->>'operator_quantity', '')::numeric,
      operator_line_snapshot = COALESCE(v_line->'operator_line_snapshot', '{}'::jsonb)
    WHERE draft_id = p_draft_id
      AND line_index = (v_line->>'line_index')::integer;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Draft line % not found for draft %', v_line->>'line_index', p_draft_id;
    END IF;
  END LOOP;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    p_draft_id,
    'SUBMIT_REVIEW',
    'AI_DRAFT',
    'UNDER_REVIEW',
    p_actor_id,
    p_actor_name,
    p_audit_metadata
  );

  RETURN p_draft_id;
END;
$$;


ALTER FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") IS 'Atomically syncs operator final and submits when extraction version matches.';



CREATE OR REPLACE FUNCTION "public"."support_ticket_set_customer_context"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'auth'
    AS $_$
declare
  actor_id uuid := auth.uid();
  actor_company_id uuid;
  actor_is_admin boolean := false;
begin
  new.updated_at := now();

  if tg_op = 'UPDATE' then
    return new;
  end if;

  if auth.role() = 'service_role' then
    return new;
  end if;

  if actor_id is null then
    raise exception 'authentication required';
  end if;

  select exists (
    select 1
    from public.users u
    where u.id = actor_id
      and u.role in ('admin', 'super_admin')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
  ) into actor_is_admin;

  if actor_is_admin then
    new.created_by := coalesce(new.created_by, actor_id);
    new.user_id := coalesce(new.user_id, actor_id);
    return new;
  end if;

  select candidate.company_id
  into actor_company_id
  from (
    select p.company_id, 1 as priority
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = actor_id
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union all

    select u.company_id, 2 as priority
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = actor_id
      and u.company_id is not null
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  ) candidate
  order by candidate.priority
  limit 1;

  if actor_company_id is null then
    raise exception 'approved customer company required';
  end if;

  if new.order_id is null
     or new.order_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     or not exists (
       select 1 from public.orders o
       where o.id = new.order_id::uuid
         and o.company_id = actor_company_id
         and coalesce(o.is_waste, false) is false
         and coalesce(o.is_duplicate, false) is false
     ) then
    raise exception 'order is not available to the authenticated company';
  end if;

  new.company_id := actor_company_id;
  new.created_by := actor_id;
  new.user_id := actor_id;
  new.status := coalesce(nullif(btrim(new.status), ''), 'open');
  new.resolution_notes := null;
  new.routed_to_department := null;
  new.assigned_employee_id := null;
  new.sla_first_response_at := null;
  new.sla_action_at := null;
  new.sla_resolved_at := null;
  new.sla_state := null;
  new.estimated_financial_loss := null;
  new.admin_rating_speed := null;
  new.admin_rating_quality := null;
  new.admin_rating_communication := null;
  new.rejection_reason_template := null;
  new.resolution_template_used := null;
  new.ai_rewritten_reply := null;
  new.escalated_to_hod := false;
  new.commission_blocked := false;

  return new;
end;
$_$;


ALTER FUNCTION "public"."support_ticket_set_customer_context"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_starter_packs_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;


ALTER FUNCTION "public"."touch_starter_packs_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text" DEFAULT NULL::"text", "p_rejection_reason" "text" DEFAULT NULL::"text", "p_approver_id" "uuid" DEFAULT NULL::"uuid", "p_approver_name" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_draft_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to transition sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  UPDATE public.sales_order_drafts
  SET
    status = p_next_status,
    updated_by = p_actor_id,
    review_notes = COALESCE(p_review_notes, review_notes),
    rejection_reason = COALESCE(p_rejection_reason, rejection_reason),
    approver_id = COALESCE(p_approver_id, approver_id),
    approver_name = COALESCE(p_approver_name, approver_name)
  WHERE id = p_draft_id
    AND status = p_expected_status
  RETURNING id INTO v_draft_id;

  IF v_draft_id IS NULL THEN
    RAISE EXCEPTION 'Concurrent or stale transition: draft is no longer %', p_expected_status;
  END IF;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    p_draft_id,
    p_action,
    p_expected_status,
    p_next_status,
    p_actor_id,
    p_actor_name,
    p_metadata
  );

  RETURN v_draft_id;
END;
$$;


ALTER FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") IS 'Atomically transitions sales_order_drafts status and appends audit log row.';



CREATE OR REPLACE FUNCTION "public"."update_outstanding_on_order"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  terms text;
  delta numeric := 0;
BEGIN
  IF NEW.company_id IS NULL THEN RETURN NEW; END IF;
  SELECT payment_terms INTO terms FROM public.companies WHERE id = NEW.company_id;
  IF terms IS DISTINCT FROM 'credit' THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status NOT IN ('draft','cart','cancelled') THEN
      delta := COALESCE(NEW.sales_order_value, 0);
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    -- Reverse old contribution if it was counted
    IF OLD.status NOT IN ('draft','cart','cancelled') THEN
      delta := delta - COALESCE(OLD.sales_order_value, 0);
    END IF;
    IF NEW.status NOT IN ('draft','cart','cancelled') THEN
      delta := delta + COALESCE(NEW.sales_order_value, 0);
    END IF;
  END IF;

  IF delta <> 0 THEN
    UPDATE public.companies
       SET total_outstanding = GREATEST(0, COALESCE(total_outstanding,0) + delta)
     WHERE id = NEW.company_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_outstanding_on_order"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_status text;
  v_extraction_request_key text;
  v_line jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_whatsapp_inbox_reader(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to update sales order drafts';
  END IF;

  IF p_actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Actor id must match authenticated user';
  END IF;

  IF NULLIF(trim(p_expected_extraction_request_key), '') IS NULL THEN
    RAISE EXCEPTION 'Expected extraction request key is required';
  END IF;

  SELECT d.status, d.extraction_request_key
  INTO v_status, v_extraction_request_key
  FROM public.sales_order_drafts d
  WHERE d.id = p_draft_id
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Sales order draft not found';
  END IF;

  IF v_status IN ('APPROVED_FOR_SO', 'REJECTED') THEN
    RAISE EXCEPTION 'Cannot update operator final in terminal status %', v_status;
  END IF;

  IF v_extraction_request_key IS DISTINCT FROM trim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'Extraction version mismatch for draft %', p_draft_id;
  END IF;

  UPDATE public.sales_order_drafts
  SET
    operator_final_snapshot = COALESCE(p_operator_final_snapshot, '{}'::jsonb),
    readiness_overall_score = COALESCE(p_readiness_overall_score, 0),
    readiness_dimensions = COALESCE(p_readiness_dimensions, '[]'::jsonb),
    updated_by = p_actor_id
  WHERE id = p_draft_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb))
  LOOP
    UPDATE public.sales_order_draft_lines
    SET
      operator_quantity = NULLIF(v_line->>'operator_quantity', '')::numeric,
      operator_line_snapshot = COALESCE(v_line->'operator_line_snapshot', '{}'::jsonb)
    WHERE draft_id = p_draft_id
      AND line_index = (v_line->>'line_index')::integer;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Draft line % not found for draft %', v_line->>'line_index', p_draft_id;
    END IF;
  END LOOP;

  INSERT INTO public.sales_order_draft_audit_log (
    draft_id,
    action,
    from_status,
    to_status,
    actor_id,
    actor_name,
    metadata
  ) VALUES (
    p_draft_id,
    'UPDATE_OPERATOR_FINAL',
    v_status,
    v_status,
    p_actor_id,
    p_actor_name,
    p_audit_metadata
  );

  RETURN p_draft_id;
END;
$$;


ALTER FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") IS 'Atomically updates operator_final snapshot when extraction version matches.';



CREATE OR REPLACE FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
  v_key text;
  v_dim jsonb;
  v_required text[] := ARRAY['client', 'product', 'quantity', 'address', 'payment_terms'];
  v_min_score constant integer := 40;
BEGIN
  FOREACH v_key IN ARRAY v_required
  LOOP
    SELECT elem
    INTO v_dim
    FROM jsonb_array_elements(COALESCE(p_dimensions, '[]'::jsonb)) AS elem
    WHERE elem->>'dimension' = v_key
    LIMIT 1;

    IF v_dim IS NULL THEN
      RAISE EXCEPTION 'Missing readiness dimension: %', v_key;
    END IF;

    IF COALESCE(v_dim->>'status', 'missing') = 'missing'
      OR COALESCE((v_dim->>'score')::integer, 0) < v_min_score THEN
      RAISE EXCEPTION '% is not ready (% — %)', v_key, v_dim->>'score', v_dim->>'status';
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") IS 'Validates all five readiness dimensions meet minimum approval threshold.';



CREATE TABLE IF NOT EXISTS "cleanup_archive"."auth_user_snapshot_20260722" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "phone" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "last_sign_in_at" timestamp with time zone,
    "email_confirmed_at" timestamp with time zone,
    "phone_confirmed_at" timestamp with time zone,
    "banned_until" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "is_sso_user" boolean,
    "is_anonymous" boolean,
    "raw_app_meta_data" "jsonb",
    "raw_user_meta_data" "jsonb"
);


ALTER TABLE "cleanup_archive"."auth_user_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_table" "text" NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "performed_by" "uuid",
    "payload_snapshot" "jsonb",
    "before_snapshot" "jsonb",
    "after_snapshot" "jsonb",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."catalogue_product_draft_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'products'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_product_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_product_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "cleanup_archive"."catalogue_product_draft_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."catalogue_version_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "sku_id" "uuid",
    "version_code" "text" NOT NULL,
    "version_number" integer NOT NULL,
    "snapshot_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "published_at" timestamp with time zone,
    "synced_to_central_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'pending_approval'::"text", 'approved'::"text", 'published'::"text", 'synced'::"text"])))
);


ALTER TABLE "cleanup_archive"."catalogue_version_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."deleted_order_manifest_20260722" (
    "id" "uuid" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."deleted_order_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."deleted_product_manifest_20260722" (
    "id" "uuid" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."deleted_product_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."deleted_user_manifest_20260722" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "created_at" timestamp with time zone,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."deleted_user_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_ai_drafts_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "version_number" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "catalogue_title" "text" DEFAULT ''::"text" NOT NULL,
    "short_description" "text" DEFAULT ''::"text" NOT NULL,
    "long_description" "text" DEFAULT ''::"text" NOT NULL,
    "b2b_sales_copy" "text" DEFAULT ''::"text" NOT NULL,
    "export_catalogue_copy" "text" DEFAULT ''::"text" NOT NULL,
    "whatsapp_product_message" "text" DEFAULT ''::"text" NOT NULL,
    "hindi_description" "text" DEFAULT ''::"text" NOT NULL,
    "storage_shelf_life_copy" "text" DEFAULT ''::"text" NOT NULL,
    "hero_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "square_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "closeup_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "packaging_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "lifestyle_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "export_bundle_preview" "text" DEFAULT ''::"text" NOT NULL,
    "source_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "rejection_reason" "text",
    "published_at" timestamp with time zone,
    "published_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_ai_studio_drafts_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'UNDER_REVIEW'::"text", 'APPROVED'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_ai_drafts_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_catalogue_versions_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "sku_id" "uuid",
    "version_code" "text" NOT NULL,
    "version_number" integer NOT NULL,
    "snapshot_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "published_at" timestamp with time zone,
    "synced_to_central_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'pending_approval'::"text", 'approved'::"text", 'published'::"text", 'synced'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_catalogue_versions_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_order_items_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "product_id" "uuid",
    "quantity" numeric DEFAULT 0 NOT NULL,
    "pack_size" "text",
    "carton_type" "text",
    "notes" "text",
    "department" "text",
    "production_status" "text" DEFAULT 'pending'::"text",
    "task_type" "text" DEFAULT 'customer'::"text",
    "actual_packed_qty" integer,
    "weight_kg" numeric
);


ALTER TABLE "cleanup_archive"."final_order_items_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_order_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "sales_order_value" numeric DEFAULT 0,
    "advance_required" numeric DEFAULT 0,
    "advance_paid" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "payment_status" "text" DEFAULT 'unpaid'::"text",
    "closed_at" timestamp with time zone,
    "closed_by" "uuid",
    "is_export" boolean DEFAULT false,
    "port_of_discharge" "text",
    "country_of_origin" "text" DEFAULT 'India'::"text",
    "document_stage" "text" DEFAULT 'SO'::"text",
    "payment_cleared" boolean DEFAULT false,
    "eway_bill_number" "text",
    "payment_receipt_url" "text",
    "estimated_despatch_date" "date",
    "actual_despatch_date" "date",
    "tracking_number" "text",
    "courier_name" "text",
    "proforma_invoice_url" "text",
    "final_invoice_url" "text",
    "eway_bill_url" "text",
    "requested_dispatch_date" "date",
    "dispatch_urgency" "text" DEFAULT 'standard'::"text",
    "admin_promised_date" "date",
    "system_estimated_date" "date",
    "gate_pass_number" "text",
    "tracking_token" "text",
    "is_starter_pack" boolean DEFAULT false NOT NULL,
    "total_weight_kg" numeric,
    "parser_confidence" numeric,
    "needs_clarification" boolean DEFAULT false NOT NULL,
    "is_waste" boolean DEFAULT false NOT NULL,
    "wamid" "text",
    "is_duplicate" boolean DEFAULT false NOT NULL,
    "duplicate_of_order_id" "uuid",
    "order_number" "text" NOT NULL,
    "finance_verified_by" "uuid",
    "finance_verified_at" timestamp with time zone,
    "payment_rejection_reason" "text"
);


ALTER TABLE "cleanup_archive"."final_order_snapshot_20260722" OWNER TO "postgres";


COMMENT ON COLUMN "cleanup_archive"."final_order_snapshot_20260722"."is_starter_pack" IS 'True when the draft was created via Growth Intelligence Starter Builder. Cart waives carton-fill / MOQ enforcement for these orders so Grand Total exactly matches the displayed Estimated Investment.';



COMMENT ON COLUMN "cleanup_archive"."final_order_snapshot_20260722"."order_number" IS 'Human-readable sales order reference SO-YYYY-NNNNNN (unique).';



COMMENT ON COLUMN "cleanup_archive"."final_order_snapshot_20260722"."finance_verified_by" IS 'UUID of finance executive who verified payment or approved credit';



COMMENT ON COLUMN "cleanup_archive"."final_order_snapshot_20260722"."finance_verified_at" IS 'Timestamp when finance cleared this order for operations';



COMMENT ON COLUMN "cleanup_archive"."final_order_snapshot_20260722"."payment_rejection_reason" IS 'Latest finance rejection message when payment is sent back to awaiting_receipt; cleared when buyer uploads a new receipt or finance verifies/credits.';



CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_aliases_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alias_text" "text" NOT NULL,
    "canonical_name" "text" NOT NULL,
    "product_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."final_product_aliases_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_bom_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "component_product_id" "uuid",
    "component_name" "text",
    "quantity_per_unit" numeric DEFAULT 1 NOT NULL,
    "source_department" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bom_type" "text" DEFAULT 'internal_bom'::"text" NOT NULL,
    CONSTRAINT "product_bom_bom_type_check" CHECK (("bom_type" = ANY (ARRAY['internal_bom'::"text", 'hamper_bom'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_product_bom_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_media_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "file_url" "text" NOT NULL,
    "type" "text",
    "status" "text" DEFAULT 'raw'::"text",
    "angle" "text",
    "alt_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."final_product_media_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_moq_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "channel" "text" NOT NULL,
    "customer_type" "text",
    "moq_applicable" boolean DEFAULT false NOT NULL,
    "allow_override" boolean DEFAULT false NOT NULL,
    "moq_value" numeric,
    "moq_uom" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "min_carton_qty" numeric,
    "carton_logic" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."final_product_moq_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_pricing_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "price_channel" "text" NOT NULL,
    "price_type" "text" DEFAULT 'quotation_based'::"text" NOT NULL,
    "base_price" numeric,
    "discount_percent" numeric,
    "calculated_price" numeric,
    "currency" "text" DEFAULT 'INR'::"text" NOT NULL,
    "uom" "text",
    "gst_rate" numeric,
    "tax_inclusive" boolean DEFAULT false NOT NULL,
    "source" "text" DEFAULT 'catalogue_local'::"text" NOT NULL,
    "approval_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "valid_from" "date",
    "valid_until" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."final_product_pricing_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_product_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "category_id" "uuid",
    "price_per_kg" numeric DEFAULT 0,
    "pack_size" "text",
    "carton_type" "text",
    "storage_type" "text",
    "description" "text",
    "shelf_life" "text",
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    "category" "text" NOT NULL,
    "sku" "text" NOT NULL,
    "mrp" numeric,
    "wholesale_price" numeric,
    "weight_per_pc_grams" numeric,
    "net_weight_grams" numeric,
    "moq" numeric DEFAULT 1,
    "packs_per_master_carton" numeric,
    "hsn_code" "text" NOT NULL,
    "gst_percentage" numeric,
    "dietary_tags" "text"[],
    "sub_category" "text",
    "department" "text",
    "base_price" numeric DEFAULT 0,
    "price_bulk" numeric DEFAULT 0,
    "price_wholesale" numeric DEFAULT 0,
    "price_horeca" numeric DEFAULT 0,
    "price_b2b" numeric DEFAULT 0,
    "price_special" numeric DEFAULT 0,
    "uom" "text" DEFAULT 'Pack'::"text",
    "avg_weight_per_pc" numeric,
    "avg_weight_per_pack" numeric,
    "packs_per_carton" numeric,
    "moq_packs" numeric DEFAULT 1,
    "private_label_moq" numeric,
    "private_label_price" numeric,
    "nutrition_facts" "text",
    "mrp_per_pc" numeric,
    "festival_tags" "text",
    "pcs_per_master_carton" numeric,
    "primary_pack_weight_kg" numeric DEFAULT 0 NOT NULL,
    "gst_rate" numeric DEFAULT 5,
    "ingredients" "text",
    "nutritional_info" "jsonb",
    "allergen_warnings" "text",
    "shelf_life_days" integer,
    "gross_weight_grams" integer,
    "storage_instructions" "text",
    "barcode_sku" "text",
    "default_store" "text" DEFAULT 'ready_goods'::"text",
    "production_department" "text",
    "settlement_unit" "text" DEFAULT 'KG'::"text",
    "visible_in_catalog" boolean DEFAULT true NOT NULL,
    "weight_per_box_kg" numeric,
    "grams_per_piece" numeric,
    "aliases" "text"[] DEFAULT '{}'::"text"[],
    "product_family" "text",
    "dimensions" "text",
    "material" "text",
    "gross_weight_kg" numeric,
    "bom_summary" "text",
    "cost_per_pc" numeric DEFAULT 0,
    "cost_per_kg" numeric DEFAULT 0,
    "cost_per_primary_pack" numeric DEFAULT 0,
    "cost_per_master_carton" numeric DEFAULT 0,
    "mrp_per_kg" numeric DEFAULT 0,
    "mrp_per_primary_pack" numeric DEFAULT 0,
    "mrp_per_master_carton" numeric DEFAULT 0,
    "price_b2b_per_pack" numeric DEFAULT 0,
    "price_b2b_per_carton" numeric DEFAULT 0,
    "pcs_per_primary_pack" numeric DEFAULT 0,
    "pcs_per_kg" numeric DEFAULT 0,
    "kg_per_primary_pack" numeric DEFAULT 0,
    "kg_per_master_carton" numeric DEFAULT 0,
    "retail_uom" "text" DEFAULT 'pc'::"text",
    "b2b_uom" "text" DEFAULT 'kg'::"text",
    "bom_required" boolean DEFAULT false NOT NULL,
    "carton_logic" "text",
    "carton_qty" numeric,
    "carton_uom" "text",
    "fixed_carton_required" boolean DEFAULT false,
    "moq_value" numeric,
    "moq_uom" "text",
    "moq_text" "text",
    "primary_uom" "text",
    "pricing_notes" "text",
    "operational_notes" "text",
    "category_code" "text",
    "subcategory_code" "text",
    "division_code" "text",
    "packaging_code" "text",
    "serial_no" numeric,
    "legacy_sku" "text",
    "external_reference_code" "text",
    "product_name" "text",
    "short_name" "text",
    "product_type" "text",
    "product_class" "text",
    "short_description" "text",
    "currency" "text" DEFAULT 'INR'::"text",
    "hero_image_url" "text",
    "label_status" "text" DEFAULT 'draft'::"text",
    "media_status" "text" DEFAULT 'missing'::"text",
    "sku_locked" boolean DEFAULT true,
    "main_department" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "master_carton_qty" numeric,
    "master_carton_uom" "text",
    "dimension_l_cm" numeric,
    "dimension_w_cm" numeric,
    "dimension_h_cm" numeric,
    "product_dimensions_cm" "text",
    "pcs_per_pack" numeric,
    "pcs_per_carton" numeric,
    "net_weight_g" numeric,
    "gross_weight_g" numeric,
    "private_label_allowed" boolean DEFAULT false,
    "private_label_moq_uom" "text",
    "private_label_cost_per_unit" numeric,
    "private_label_upfront_cost" numeric,
    "customization_allowed" boolean DEFAULT false,
    "customization_note" "text",
    "customization_caution" "text",
    "frozen_shelf_life_days" integer,
    "post_processing_shelf_life_days" integer,
    "temperature_requirement" "text",
    "thawing_instruction" "text",
    "material_type" "text",
    "color_finish_notes" "text",
    "is_catalogue_ready" boolean DEFAULT false,
    "is_sample" boolean DEFAULT false,
    "moq_rule_type" "text",
    "subcategory" "text",
    "unit_conversion_note" "text",
    CONSTRAINT "products_default_store_check" CHECK (("default_store" = ANY (ARRAY['ready_goods'::"text", 'packing_assembly'::"text", '3rd_party'::"text"]))),
    CONSTRAINT "products_production_department_check" CHECK ((("production_department" IS NULL) OR ("production_department" = ANY (ARRAY['arabic_sweets'::"text", 'dragees'::"text", 'fusion_sweets'::"text", 'chocolates_confectionery'::"text", 'seasoned_nuts_mixes'::"text", 'bakery'::"text"])))),
    CONSTRAINT "products_storage_type_check" CHECK (("storage_type" = ANY (ARRAY['ambient'::"text", 'cool'::"text", 'frozen'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_product_snapshot_20260722" OWNER TO "postgres";


COMMENT ON COLUMN "cleanup_archive"."final_product_snapshot_20260722"."product_family" IS 'High-level family used for category-aware UI: bulk_sweets | goldware | hampers | retail_pack. Optional — falls back to category inference.';



COMMENT ON COLUMN "cleanup_archive"."final_product_snapshot_20260722"."dimensions" IS 'Free-text size for non-food items (e.g. "12-inch", "10 x 8 in").';



COMMENT ON COLUMN "cleanup_archive"."final_product_snapshot_20260722"."material" IS 'Construction material for goldware/packaging (e.g. "Brass", "Acrylic").';



COMMENT ON COLUMN "cleanup_archive"."final_product_snapshot_20260722"."gross_weight_kg" IS 'Total shipping weight for hampers / gift packs including packaging.';



COMMENT ON COLUMN "cleanup_archive"."final_product_snapshot_20260722"."bom_summary" IS 'Human-readable summary of included items for hampers (e.g. "2x Asabi 250g, 1x Pyramid 500g").';



CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source" "text" DEFAULT 'whatsapp_inbound'::"text" NOT NULL,
    "source_message_id" "uuid" NOT NULL,
    "sender_phone" "text" NOT NULL,
    "customer_name" "text",
    "message_body" "text" NOT NULL,
    "resolved_product_id" "uuid",
    "resolved_sku" "text" NOT NULL,
    "resolved_product_name" "text",
    "confidence_band" "text" NOT NULL,
    "operator_decision" "text" NOT NULL,
    "status" "text" DEFAULT 'UNDER_REVIEW'::"text" NOT NULL,
    "quantity" numeric DEFAULT 1 NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_sales_order_drafts_confidence_band_check" CHECK (("confidence_band" = ANY (ARRAY['HIGH'::"text", 'MEDIUM'::"text", 'LOW'::"text"]))),
    CONSTRAINT "whatsapp_sales_order_drafts_operator_decision_check" CHECK (("operator_decision" = ANY (ARRAY['confirmed'::"text", 'alternative_selected'::"text"]))),
    CONSTRAINT "whatsapp_sales_order_drafts_quantity_check" CHECK (("quantity" > (0)::numeric)),
    CONSTRAINT "whatsapp_sales_order_drafts_source_check" CHECK (("source" = 'whatsapp_inbound'::"text")),
    CONSTRAINT "whatsapp_sales_order_drafts_status_check" CHECK (("status" = ANY (ARRAY['AI_DRAFT'::"text", 'UNDER_REVIEW'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."final_whatsapp_operator_decisions_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_message_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "sku" "text",
    "product_name" "text",
    "confidence_band" "text",
    "whatsapp_sales_order_draft_id" "uuid",
    "decided_by" "uuid" NOT NULL,
    "decided_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_operator_decisions_action_check" CHECK (("action" = ANY (ARRAY['confirm'::"text", 'reject'::"text", 'select_alternative'::"text"])))
);


ALTER TABLE "cleanup_archive"."final_whatsapp_operator_decisions_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."order_delete_manifest_20260722" (
    "order_id" "uuid" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text" NOT NULL
);


ALTER TABLE "cleanup_archive"."order_delete_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."order_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "sales_order_value" numeric DEFAULT 0,
    "advance_required" numeric DEFAULT 0,
    "advance_paid" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "payment_status" "text" DEFAULT 'unpaid'::"text",
    "closed_at" timestamp with time zone,
    "closed_by" "uuid",
    "is_export" boolean DEFAULT false,
    "port_of_discharge" "text",
    "country_of_origin" "text" DEFAULT 'India'::"text",
    "document_stage" "text" DEFAULT 'SO'::"text",
    "payment_cleared" boolean DEFAULT false,
    "eway_bill_number" "text",
    "payment_receipt_url" "text",
    "estimated_despatch_date" "date",
    "actual_despatch_date" "date",
    "tracking_number" "text",
    "courier_name" "text",
    "proforma_invoice_url" "text",
    "final_invoice_url" "text",
    "eway_bill_url" "text",
    "requested_dispatch_date" "date",
    "dispatch_urgency" "text" DEFAULT 'standard'::"text",
    "admin_promised_date" "date",
    "system_estimated_date" "date",
    "gate_pass_number" "text",
    "tracking_token" "text",
    "is_starter_pack" boolean DEFAULT false NOT NULL,
    "total_weight_kg" numeric,
    "parser_confidence" numeric,
    "needs_clarification" boolean DEFAULT false NOT NULL,
    "is_waste" boolean DEFAULT false NOT NULL,
    "wamid" "text",
    "is_duplicate" boolean DEFAULT false NOT NULL,
    "duplicate_of_order_id" "uuid",
    "order_number" "text" NOT NULL,
    "finance_verified_by" "uuid",
    "finance_verified_at" timestamp with time zone,
    "payment_rejection_reason" "text"
);


ALTER TABLE "cleanup_archive"."order_snapshot_20260722" OWNER TO "postgres";


COMMENT ON COLUMN "cleanup_archive"."order_snapshot_20260722"."is_starter_pack" IS 'True when the draft was created via Growth Intelligence Starter Builder. Cart waives carton-fill / MOQ enforcement for these orders so Grand Total exactly matches the displayed Estimated Investment.';



COMMENT ON COLUMN "cleanup_archive"."order_snapshot_20260722"."order_number" IS 'Human-readable sales order reference SO-YYYY-NNNNNN (unique).';



COMMENT ON COLUMN "cleanup_archive"."order_snapshot_20260722"."finance_verified_by" IS 'UUID of finance executive who verified payment or approved credit';



COMMENT ON COLUMN "cleanup_archive"."order_snapshot_20260722"."finance_verified_at" IS 'Timestamp when finance cleared this order for operations';



COMMENT ON COLUMN "cleanup_archive"."order_snapshot_20260722"."payment_rejection_reason" IS 'Latest finance rejection message when payment is sent back to awaiting_receipt; cleared when buyer uploads a new receipt or finance verifies/credits.';



CREATE TABLE IF NOT EXISTS "cleanup_archive"."product_alias_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alias_text" "text" NOT NULL,
    "canonical_name" "text" NOT NULL,
    "product_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."product_alias_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."product_moq_rule_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "channel" "text" NOT NULL,
    "customer_type" "text",
    "moq_applicable" boolean DEFAULT false NOT NULL,
    "allow_override" boolean DEFAULT false NOT NULL,
    "moq_value" numeric,
    "moq_uom" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "min_carton_qty" numeric,
    "carton_logic" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."product_moq_rule_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."product_pricing_rule_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "price_channel" "text" NOT NULL,
    "price_type" "text" DEFAULT 'quotation_based'::"text" NOT NULL,
    "base_price" numeric,
    "discount_percent" numeric,
    "calculated_price" numeric,
    "currency" "text" DEFAULT 'INR'::"text" NOT NULL,
    "uom" "text",
    "gst_rate" numeric,
    "tax_inclusive" boolean DEFAULT false NOT NULL,
    "source" "text" DEFAULT 'catalogue_local'::"text" NOT NULL,
    "approval_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "valid_from" "date",
    "valid_until" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "cleanup_archive"."product_pricing_rule_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."product_snapshot_20260722" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "category_id" "uuid",
    "price_per_kg" numeric DEFAULT 0,
    "pack_size" "text",
    "carton_type" "text",
    "storage_type" "text",
    "description" "text",
    "shelf_life" "text",
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    "category" "text" NOT NULL,
    "sku" "text" NOT NULL,
    "mrp" numeric,
    "wholesale_price" numeric,
    "weight_per_pc_grams" numeric,
    "net_weight_grams" numeric,
    "moq" numeric DEFAULT 1,
    "packs_per_master_carton" numeric,
    "hsn_code" "text" NOT NULL,
    "gst_percentage" numeric,
    "dietary_tags" "text"[],
    "sub_category" "text",
    "department" "text",
    "base_price" numeric DEFAULT 0,
    "price_bulk" numeric DEFAULT 0,
    "price_wholesale" numeric DEFAULT 0,
    "price_horeca" numeric DEFAULT 0,
    "price_b2b" numeric DEFAULT 0,
    "price_special" numeric DEFAULT 0,
    "uom" "text" DEFAULT 'Pack'::"text",
    "avg_weight_per_pc" numeric,
    "avg_weight_per_pack" numeric,
    "packs_per_carton" numeric,
    "moq_packs" numeric DEFAULT 1,
    "private_label_moq" numeric,
    "private_label_price" numeric,
    "nutrition_facts" "text",
    "mrp_per_pc" numeric,
    "festival_tags" "text",
    "pcs_per_master_carton" numeric,
    "primary_pack_weight_kg" numeric DEFAULT 0 NOT NULL,
    "gst_rate" numeric DEFAULT 5,
    "ingredients" "text",
    "nutritional_info" "jsonb",
    "allergen_warnings" "text",
    "shelf_life_days" integer,
    "gross_weight_grams" integer,
    "storage_instructions" "text",
    "barcode_sku" "text",
    "default_store" "text" DEFAULT 'ready_goods'::"text",
    "production_department" "text",
    "settlement_unit" "text" DEFAULT 'KG'::"text",
    "visible_in_catalog" boolean DEFAULT true NOT NULL,
    "weight_per_box_kg" numeric,
    "grams_per_piece" numeric,
    "aliases" "text"[] DEFAULT '{}'::"text"[],
    "product_family" "text",
    "dimensions" "text",
    "material" "text",
    "gross_weight_kg" numeric,
    "bom_summary" "text",
    "cost_per_pc" numeric DEFAULT 0,
    "cost_per_kg" numeric DEFAULT 0,
    "cost_per_primary_pack" numeric DEFAULT 0,
    "cost_per_master_carton" numeric DEFAULT 0,
    "mrp_per_kg" numeric DEFAULT 0,
    "mrp_per_primary_pack" numeric DEFAULT 0,
    "mrp_per_master_carton" numeric DEFAULT 0,
    "price_b2b_per_pack" numeric DEFAULT 0,
    "price_b2b_per_carton" numeric DEFAULT 0,
    "pcs_per_primary_pack" numeric DEFAULT 0,
    "pcs_per_kg" numeric DEFAULT 0,
    "kg_per_primary_pack" numeric DEFAULT 0,
    "kg_per_master_carton" numeric DEFAULT 0,
    "retail_uom" "text" DEFAULT 'pc'::"text",
    "b2b_uom" "text" DEFAULT 'kg'::"text",
    "bom_required" boolean DEFAULT false NOT NULL,
    "carton_logic" "text",
    "carton_qty" numeric,
    "carton_uom" "text",
    "fixed_carton_required" boolean DEFAULT false,
    "moq_value" numeric,
    "moq_uom" "text",
    "moq_text" "text",
    "primary_uom" "text",
    "pricing_notes" "text",
    "operational_notes" "text",
    "category_code" "text",
    "subcategory_code" "text",
    "division_code" "text",
    "packaging_code" "text",
    "serial_no" numeric,
    "legacy_sku" "text",
    "external_reference_code" "text",
    "product_name" "text",
    "short_name" "text",
    "product_type" "text",
    "product_class" "text",
    "short_description" "text",
    "currency" "text" DEFAULT 'INR'::"text",
    "hero_image_url" "text",
    "label_status" "text" DEFAULT 'draft'::"text",
    "media_status" "text" DEFAULT 'missing'::"text",
    "sku_locked" boolean DEFAULT true,
    "main_department" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "master_carton_qty" numeric,
    "master_carton_uom" "text",
    "dimension_l_cm" numeric,
    "dimension_w_cm" numeric,
    "dimension_h_cm" numeric,
    "product_dimensions_cm" "text",
    "pcs_per_pack" numeric,
    "pcs_per_carton" numeric,
    "net_weight_g" numeric,
    "gross_weight_g" numeric,
    "private_label_allowed" boolean DEFAULT false,
    "private_label_moq_uom" "text",
    "private_label_cost_per_unit" numeric,
    "private_label_upfront_cost" numeric,
    "customization_allowed" boolean DEFAULT false,
    "customization_note" "text",
    "customization_caution" "text",
    "frozen_shelf_life_days" integer,
    "post_processing_shelf_life_days" integer,
    "temperature_requirement" "text",
    "thawing_instruction" "text",
    "material_type" "text",
    "color_finish_notes" "text",
    "is_catalogue_ready" boolean DEFAULT false,
    "is_sample" boolean DEFAULT false,
    "moq_rule_type" "text",
    "subcategory" "text",
    "unit_conversion_note" "text",
    CONSTRAINT "products_default_store_check" CHECK (("default_store" = ANY (ARRAY['ready_goods'::"text", 'packing_assembly'::"text", '3rd_party'::"text"]))),
    CONSTRAINT "products_production_department_check" CHECK ((("production_department" IS NULL) OR ("production_department" = ANY (ARRAY['arabic_sweets'::"text", 'dragees'::"text", 'fusion_sweets'::"text", 'chocolates_confectionery'::"text", 'seasoned_nuts_mixes'::"text", 'bakery'::"text"])))),
    CONSTRAINT "products_storage_type_check" CHECK (("storage_type" = ANY (ARRAY['ambient'::"text", 'cool'::"text", 'frozen'::"text"])))
);


ALTER TABLE "cleanup_archive"."product_snapshot_20260722" OWNER TO "postgres";


COMMENT ON COLUMN "cleanup_archive"."product_snapshot_20260722"."product_family" IS 'High-level family used for category-aware UI: bulk_sweets | goldware | hampers | retail_pack. Optional — falls back to category inference.';



COMMENT ON COLUMN "cleanup_archive"."product_snapshot_20260722"."dimensions" IS 'Free-text size for non-food items (e.g. "12-inch", "10 x 8 in").';



COMMENT ON COLUMN "cleanup_archive"."product_snapshot_20260722"."material" IS 'Construction material for goldware/packaging (e.g. "Brass", "Acrylic").';



COMMENT ON COLUMN "cleanup_archive"."product_snapshot_20260722"."gross_weight_kg" IS 'Total shipping weight for hampers / gift packs including packaging.';



COMMENT ON COLUMN "cleanup_archive"."product_snapshot_20260722"."bom_summary" IS 'Human-readable summary of included items for hampers (e.g. "2x Asabi 250g, 1x Pyramid 500g").';



CREATE TABLE IF NOT EXISTS "cleanup_archive"."support_only_product_delete_manifest_20260722" (
    "product_id" "uuid" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text" NOT NULL
);


ALTER TABLE "cleanup_archive"."support_only_product_delete_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."support_ticket_orphan_snapshot_20260722" (
    "id" "uuid",
    "order_id" "text",
    "user_id" "uuid",
    "issue_type" "text",
    "description" "text",
    "status" "text",
    "created_at" timestamp with time zone,
    "created_by" "uuid",
    "resolution_notes" "text",
    "product_sku" "text",
    "qty_affected" integer,
    "proof_url" "text",
    "dispatch_date" "date",
    "window_status" "text",
    "routed_to_department" "text",
    "assigned_employee_id" "uuid",
    "sla_first_response_at" timestamp with time zone,
    "sla_action_at" timestamp with time zone,
    "sla_resolved_at" timestamp with time zone,
    "sla_first_response_due" timestamp with time zone,
    "sla_action_due" timestamp with time zone,
    "sla_resolution_due" timestamp with time zone,
    "sla_state" "text",
    "severity" "text",
    "estimated_financial_loss" numeric,
    "customer_rating" integer,
    "admin_rating_speed" integer,
    "admin_rating_quality" integer,
    "admin_rating_communication" integer,
    "rejection_reason_template" "text",
    "resolution_template_used" "text",
    "ai_rewritten_reply" "text",
    "escalated_to_hod" boolean,
    "commission_blocked" boolean,
    "archived_at" timestamp with time zone,
    "archive_reason" "text"
);


ALTER TABLE "cleanup_archive"."support_ticket_orphan_snapshot_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "cleanup_archive"."user_delete_manifest_20260722" (
    "user_id" "uuid" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text" NOT NULL
);


ALTER TABLE "cleanup_archive"."user_delete_manifest_20260722" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."access_permissions" (
    "permission_key" "text" NOT NULL,
    "description" "text" NOT NULL,
    "risk_level" "text" DEFAULT 'standard'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "requires_step_up" boolean DEFAULT false NOT NULL,
    CONSTRAINT "access_permissions_risk_level_check" CHECK (("risk_level" = ANY (ARRAY['standard'::"text", 'sensitive'::"text", 'high_risk'::"text"])))
);


ALTER TABLE "public"."access_permissions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."access_permissions"."requires_step_up" IS 'When true, has_app_permission requires an AAL2 Supabase Auth session.';



CREATE TABLE IF NOT EXISTS "public"."admin_manual_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_target" "text",
    "tool_name" "text",
    "description" "text",
    "image_snapshot_url" "text",
    "step_order" integer,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admin_manual_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "setting_key" "text" NOT NULL,
    "setting_value" "jsonb",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."archive_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "action_type" "text",
    "actor_id" "uuid",
    "module_name" "text",
    "entity_name" "text",
    "entity_id" "text",
    "old_value" "jsonb",
    "new_value" "jsonb",
    "reason" "text",
    "risk_level" "text" DEFAULT 'normal'::"text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "archived_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."archive_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_id" "uuid",
    "module_name" "text",
    "entity_name" "text",
    "entity_id" "text",
    "action_type" "text",
    "old_value" "jsonb",
    "new_value" "jsonb",
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "risk_level" "text" DEFAULT 'normal'::"text"
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."auth_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text",
    "phone" "text",
    "channel" "text",
    "status" "text",
    "request_id" "text",
    "description" "text",
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_name" "text",
    "failure_reason" "text"
);


ALTER TABLE "public"."auth_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."b2b_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_name" "text" NOT NULL,
    "gst_number" "text",
    "expected_volume" "text",
    "contact_name" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid",
    "trade_name" "text",
    "business_type" "text",
    "contact_person" "text",
    "mobile_number" "text",
    "registered_address" "text",
    "city" "text",
    "state" "text",
    "pincode" "text",
    "gst_certificate_path" "text",
    "business_proof_path" "text",
    "current_brands" "text",
    "preferred_dispatch" "text",
    "preferred_dispatch_other_name" "text",
    "trade_declaration" boolean DEFAULT false,
    "data_consent" boolean DEFAULT false,
    "assigned_price_tier" "text",
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "rejection_reason" "text",
    "admin_notes" "text",
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "requested_info_at" timestamp with time zone,
    "requested_info_note" "text"
);


ALTER TABLE "public"."b2b_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bi_monthly_ledgers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "total_amount" numeric DEFAULT 0 NOT NULL,
    "order_count" integer DEFAULT 0 NOT NULL,
    "pdf_url" "text",
    "status" "text" DEFAULT 'sent'::"text" NOT NULL,
    "whatsapp_message_id" "text",
    "generated_by" "uuid",
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bi_monthly_ledgers_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'sent'::"text", 'matched'::"text", 'disputed'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."bi_monthly_ledgers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_ai_studio_draft_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "from_status" "text",
    "to_status" "text",
    "actor_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."catalogue_ai_studio_draft_audit_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."catalogue_ai_studio_draft_audit_log" IS 'Append-only audit trail for catalogue_ai_studio_drafts workflow transitions (save, submit, approve, reject, publish).';



CREATE TABLE IF NOT EXISTS "public"."catalogue_ai_studio_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "version_number" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "catalogue_title" "text" DEFAULT ''::"text" NOT NULL,
    "short_description" "text" DEFAULT ''::"text" NOT NULL,
    "long_description" "text" DEFAULT ''::"text" NOT NULL,
    "b2b_sales_copy" "text" DEFAULT ''::"text" NOT NULL,
    "export_catalogue_copy" "text" DEFAULT ''::"text" NOT NULL,
    "whatsapp_product_message" "text" DEFAULT ''::"text" NOT NULL,
    "hindi_description" "text" DEFAULT ''::"text" NOT NULL,
    "storage_shelf_life_copy" "text" DEFAULT ''::"text" NOT NULL,
    "hero_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "square_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "closeup_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "packaging_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "lifestyle_image_prompt" "text" DEFAULT ''::"text" NOT NULL,
    "export_bundle_preview" "text" DEFAULT ''::"text" NOT NULL,
    "source_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "rejection_reason" "text",
    "published_at" timestamp with time zone,
    "published_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_ai_studio_drafts_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'UNDER_REVIEW'::"text", 'APPROVED'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "public"."catalogue_ai_studio_drafts" OWNER TO "postgres";


COMMENT ON TABLE "public"."catalogue_ai_studio_drafts" IS 'Catalogue AI-Studio draft persistence, versioning, and review workflow. No external AI call and no product mutation.';



CREATE TABLE IF NOT EXISTS "public"."catalogue_alias_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'product_aliases'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_alias_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_alias_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_alias_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_approval_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_table" "text" NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "performed_by" "uuid",
    "payload_snapshot" "jsonb",
    "before_snapshot" "jsonb",
    "after_snapshot" "jsonb",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."catalogue_approval_audit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_bom_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'product_bom'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_bom_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_bom_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_bom_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_media_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'products'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_media_submissions_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_media_submissions_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_media_submissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_moq_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'moq_rules'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_moq_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_moq_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_moq_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_pricing_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'pricing_slabs'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_pricing_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_pricing_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_pricing_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_product_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'products'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_product_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_product_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_product_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_product_mappings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "external_catalogue_product_id" "text" NOT NULL,
    "central_product_id" "uuid",
    "sku" "text" NOT NULL,
    "source_app" "text" DEFAULT 'ai_catalogue_builder'::"text" NOT NULL,
    "source_version" integer DEFAULT 1 NOT NULL,
    "sync_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "last_synced_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_product_mappings_sync_status_check" CHECK (("sync_status" = ANY (ARRAY['pending'::"text", 'synced'::"text", 'deactivated'::"text", 'error'::"text", 'skipped_stale'::"text"])))
);


ALTER TABLE "public"."catalogue_product_mappings" OWNER TO "postgres";


COMMENT ON TABLE "public"."catalogue_product_mappings" IS 'Maps approved catalogue builder product IDs to Central products.id; idempotent sync by SKU.';



CREATE TABLE IF NOT EXISTS "public"."catalogue_sync_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "catalogue_version_id" "uuid" NOT NULL,
    "target_system" "text" DEFAULT 'oasis_central'::"text" NOT NULL,
    "sync_status" "text" DEFAULT 'preview_only'::"text" NOT NULL,
    "payload_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "error_message" "text",
    "triggered_by" "uuid",
    "triggered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_sync_events_sync_status_check" CHECK (("sync_status" = ANY (ARRAY['preview_only'::"text", 'pending'::"text", 'success'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."catalogue_sync_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_tag_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_app" "text" DEFAULT 'catalogue_app'::"text" NOT NULL,
    "target_table" "text" DEFAULT 'product_tags'::"text" NOT NULL,
    "target_record_id" "uuid",
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_tag_drafts_operation_check" CHECK (("operation" = ANY (ARRAY['create'::"text", 'update'::"text", 'delete_request'::"text"]))),
    CONSTRAINT "catalogue_tag_drafts_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."catalogue_tag_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."catalogue_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "sku_id" "uuid",
    "version_code" "text" NOT NULL,
    "version_number" integer NOT NULL,
    "snapshot_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "published_at" timestamp with time zone,
    "synced_to_central_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "catalogue_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'pending_approval'::"text", 'approved'::"text", 'published'::"text", 'synced'::"text"])))
);


ALTER TABLE "public"."catalogue_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "parent_id" "uuid"
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_interactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "executive_id" "uuid",
    "interaction_type" "text",
    "notes" "text",
    "follow_up_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "outcome" "text",
    CONSTRAINT "client_interactions_interaction_type_check" CHECK (("interaction_type" = ANY (ARRAY['call'::"text", 'visit'::"text", 'email'::"text", 'complaint'::"text"])))
);


ALTER TABLE "public"."client_interactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_production_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "department" "text" NOT NULL,
    "logged_by" "uuid",
    "produced_qty" integer NOT NULL,
    "wastage_qty" integer DEFAULT 0,
    "log_date" "date" DEFAULT CURRENT_DATE,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."daily_production_logs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."cmd_department_health" AS
 SELECT "department",
    "sum"("produced_qty") AS "total_produced",
    "sum"("wastage_qty") AS "total_wastage",
    "round"(((("sum"("wastage_qty"))::numeric / (NULLIF("sum"("produced_qty"), 0))::numeric) * (100)::numeric), 2) AS "wastage_rate"
   FROM "public"."daily_production_logs"
  GROUP BY "department";


ALTER VIEW "public"."cmd_department_health" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."commission_payouts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "executive_id" "uuid",
    "amount_paid" numeric NOT NULL,
    "payment_ref" "text",
    "paid_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."commission_payouts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_name" "text" NOT NULL,
    "gst_number" "text",
    "business_volume" "text",
    "website" "text",
    "credit_limit" numeric DEFAULT 0,
    "wallet_balance" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'pending'::"text",
    "current_balance" numeric(12,2) DEFAULT 0,
    "discount_percentage" numeric(5,2) DEFAULT 0,
    "preferred_courier" "text",
    "courier_account_number" "text",
    "allow_credit" boolean DEFAULT false,
    "account_manager_id" "uuid",
    "price_tier" "text" DEFAULT 'B2B'::"text",
    "phone" "text",
    "fssai_number" "text",
    "registered_address" "text",
    "payment_terms" "text" DEFAULT 'prepaid'::"text" NOT NULL,
    "is_frozen" boolean DEFAULT false NOT NULL,
    "total_outstanding" numeric DEFAULT 0 NOT NULL,
    "rescue_payment_date" timestamp with time zone,
    "settlement_deadline" timestamp with time zone,
    CONSTRAINT "companies_credit_limit_non_negative" CHECK (("credit_limit" >= (0)::numeric)),
    CONSTRAINT "companies_credit_limit_nonneg" CHECK ((("credit_limit" IS NULL) OR ("credit_limit" >= (0)::numeric))),
    CONSTRAINT "companies_payment_terms_check" CHECK (("payment_terms" = ANY (ARRAY['prepaid'::"text", 'credit'::"text"])))
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "requested_by" "uuid",
    "credit_type" "text",
    "requested_amount" numeric NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "credit_requests_credit_type_check" CHECK (("credit_type" = ANY (ARRAY['short_term_so'::"text", 'long_term_limit'::"text"]))),
    CONSTRAINT "credit_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."credit_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_rescue_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "amount" numeric DEFAULT 0,
    "outstanding_at_event" numeric DEFAULT 0,
    "notes" "text",
    "actor_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "credit_rescue_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['frozen'::"text", 'rescue_payment'::"text", 'unlocked'::"text", 'month_end_lock'::"text", 'manual_override'::"text", 'settlement_deadline_set'::"text"])))
);


ALTER TABLE "public"."credit_rescue_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "sales_exec_id" "uuid",
    "due_date" "date" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "task_type" "text" DEFAULT 'follow_up'::"text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone
);


ALTER TABLE "public"."crm_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_import_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_filename" "text" DEFAULT 'oasis_customer_master_audit_import_plan.xlsx'::"text" NOT NULL,
    "source_original_filename" "text" DEFAULT 'Copy of Party (1).xlsx'::"text",
    "source_environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "status" "text" DEFAULT 'loaded'::"text" NOT NULL,
    "row_counts" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "central_mapping" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "validation_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "loaded_by" "uuid",
    "loaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "validated_at" timestamp with time zone,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_import_batches_source_environment_check" CHECK (("source_environment" = ANY (ARRAY['staging'::"text", 'production'::"text"]))),
    CONSTRAINT "customer_import_batches_staging_only" CHECK (("source_environment" = 'staging'::"text")),
    CONSTRAINT "customer_import_batches_status_check" CHECK (("status" = ANY (ARRAY['loaded'::"text", 'validated'::"text", 'approved'::"text", 'promoted'::"text", 'rejected'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."customer_import_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_import_company_candidates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "raw_id" "uuid",
    "source_customer_key" "text" NOT NULL,
    "source_sheet" "text",
    "source_row" integer,
    "business_name" "text" NOT NULL,
    "gst_number_raw" "text",
    "gst_number_normalized" "text",
    "registered_address" "text",
    "state" "text",
    "country" "text",
    "registration_type" "text",
    "phone_raw" "text",
    "phone_secondary_raw" "text",
    "phone_last10" "text",
    "phone_secondary_last10" "text",
    "trade_name" "text",
    "city" "text",
    "pincode" "text",
    "payment_terms_raw" "text",
    "payment_terms_normalized" "text",
    "fssai_number" "text",
    "website" "text",
    "price_tier" "text",
    "status_candidate" "text",
    "account_manager_name_raw" "text",
    "account_manager_email_raw" "text",
    "account_manager_id" "uuid",
    "matched_company_id" "uuid",
    "match_method" "text",
    "match_confidence" numeric,
    "validation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "import_action" "text" DEFAULT 'review'::"text" NOT NULL,
    "validation_messages" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_import_company_candidat_payment_terms_normalized_check" CHECK ((("payment_terms_normalized" IS NULL) OR ("payment_terms_normalized" = ANY (ARRAY['prepaid'::"text", 'credit'::"text"])))),
    CONSTRAINT "customer_import_company_candidates_import_action_check" CHECK (("import_action" = ANY (ARRAY['create_new'::"text", 'link_existing'::"text", 'skip'::"text", 'review'::"text"]))),
    CONSTRAINT "customer_import_company_candidates_match_method_check" CHECK ((("match_method" IS NULL) OR ("match_method" = ANY (ARRAY['gst_exact'::"text", 'phone_last10'::"text", 'business_name'::"text", 'manual'::"text", 'none'::"text", 'new'::"text"])))),
    CONSTRAINT "customer_import_company_candidates_validation_status_check" CHECK (("validation_status" = ANY (ARRAY['pending'::"text", 'valid'::"text", 'warning'::"text", 'error'::"text", 'duplicate_gst_in_batch'::"text", 'duplicate_gst_existing'::"text", 'duplicate_phone_in_batch'::"text", 'duplicate_phone_existing'::"text", 'missing_required'::"text", 'review_required'::"text"])))
);


ALTER TABLE "public"."customer_import_company_candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_import_contact_candidates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "raw_id" "uuid",
    "source_contact_key" "text" NOT NULL,
    "source_customer_key" "text" NOT NULL,
    "company_name" "text" NOT NULL,
    "source_sheet" "text",
    "source_row" integer,
    "company_candidate_id" "uuid",
    "contact_name" "text",
    "whatsapp_phone_raw" "text" NOT NULL,
    "whatsapp_candidate_raw" "text",
    "whatsapp_phone_normalized" "text",
    "phone_last10" "text",
    "matched_company_id" "uuid",
    "matched_whatsapp_contact_id" "uuid",
    "matched_user_id" "uuid",
    "match_method" "text",
    "validation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "import_action" "text" DEFAULT 'review'::"text" NOT NULL,
    "validation_messages" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_import_contact_candidates_import_action_check" CHECK (("import_action" = ANY (ARRAY['create_new'::"text", 'link_existing'::"text", 'skip'::"text", 'review'::"text"]))),
    CONSTRAINT "customer_import_contact_candidates_match_method_check" CHECK ((("match_method" IS NULL) OR ("match_method" = ANY (ARRAY['phone_last10'::"text", 'whatsapp_contact'::"text", 'user_phone'::"text", 'manual'::"text", 'none'::"text", 'new'::"text"])))),
    CONSTRAINT "customer_import_contact_candidates_validation_status_check" CHECK (("validation_status" = ANY (ARRAY['pending'::"text", 'valid'::"text", 'warning'::"text", 'error'::"text", 'duplicate_phone_in_batch'::"text", 'duplicate_phone_existing'::"text", 'orphan_customer_key'::"text", 'missing_phone'::"text", 'review_required'::"text"])))
);


ALTER TABLE "public"."customer_import_contact_candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_import_duplicate_review" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "raw_id" "uuid",
    "duplicate_type" "text" NOT NULL,
    "duplicate_key_raw" "text" NOT NULL,
    "duplicate_key_normalized" "text" NOT NULL,
    "occurrence_count" integer DEFAULT 0 NOT NULL,
    "matched_companies_raw" "text",
    "candidate_source_keys" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "candidate_details" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "review_status_raw" "text",
    "resolution_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "chosen_winner_source_key" "text",
    "reviewer_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_import_duplicate_review_duplicate_type_check" CHECK (("duplicate_type" = ANY (ARRAY['phone'::"text", 'gst'::"text", 'name'::"text"]))),
    CONSTRAINT "customer_import_duplicate_review_occurrence_count_check" CHECK (("occurrence_count" >= 0)),
    CONSTRAINT "customer_import_duplicate_review_resolution_status_check" CHECK (("resolution_status" = ANY (ARRAY['pending'::"text", 'keep_one'::"text", 'merge'::"text", 'skip_all'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."customer_import_duplicate_review" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_import_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "source_tab" "text" NOT NULL,
    "source_row_number" integer NOT NULL,
    "row_json" "jsonb" NOT NULL,
    "row_hash" "text" NOT NULL,
    "parse_errors" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_import_raw_source_row_number_check" CHECK (("source_row_number" > 0)),
    CONSTRAINT "customer_import_raw_source_tab_check" CHECK (("length"(TRIM(BOTH FROM "source_tab")) > 0))
);


ALTER TABLE "public"."customer_import_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dead_letter_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_application" "text" NOT NULL,
    "workload_type" "text" NOT NULL,
    "source_table" "text" NOT NULL,
    "source_record_id" "text" NOT NULL,
    "policy_key" "text",
    "idempotency_key" "text",
    "attempt_count" integer NOT NULL,
    "error_code" "text",
    "error_message" "text" NOT NULL,
    "context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "first_failed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_failed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "requeued_at" timestamp with time zone,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "resolution_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dead_letter_attempt_count_check" CHECK (("attempt_count" >= 1)),
    CONSTRAINT "dead_letter_error_nonempty" CHECK (("btrim"("error_message") <> ''::"text")),
    CONSTRAINT "dead_letter_source_nonempty" CHECK ((("btrim"("source_application") <> ''::"text") AND ("btrim"("workload_type") <> ''::"text") AND ("btrim"("source_table") <> ''::"text") AND ("btrim"("source_record_id") <> ''::"text"))),
    CONSTRAINT "dead_letter_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'requeued'::"text", 'resolved'::"text", 'discarded'::"text"])))
);


ALTER TABLE "public"."dead_letter_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."debug_webhooks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "direction" "text" DEFAULT 'inbound'::"text" NOT NULL,
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "phone_number" "text",
    "error_message" "text",
    "processed" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "wamid" "text",
    "discard_reason" "text",
    "message_intent" "text"
);


ALTER TABLE "public"."debug_webhooks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."delivery_addresses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "label" "text" NOT NULL,
    "street_address" "text" NOT NULL,
    "city" "text" NOT NULL,
    "state" "text" NOT NULL,
    "pincode" "text" NOT NULL,
    "contact_person" "text",
    "contact_phone" "text",
    "is_default" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "user_id" "uuid"
);


ALTER TABLE "public"."delivery_addresses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dispatch_cartons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "dispatch_id" "uuid",
    "barcode_string" "text" NOT NULL,
    "box_number" integer,
    "total_boxes" integer,
    "weight_kg" numeric(10,2),
    "status" "text" DEFAULT 'labeled'::"text",
    "scanned_out_at" timestamp with time zone
);


ALTER TABLE "public"."dispatch_cartons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dispatch_completion_evidence" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "queue_item_id" "uuid",
    "evidence_type" "text" NOT NULL,
    "evidence_status" "text" NOT NULL,
    "completion_status" "text" NOT NULL,
    "evidence_ref" "text",
    "courier_ref" "text",
    "manifest_ref" "text",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "override_reason" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dispatch_completion_evidence_completion_status_check" CHECK (("completion_status" = ANY (ARRAY['not_eligible'::"text", 'prerequisites_pending'::"text", 'completion_eligible'::"text", 'completion_attested'::"text", 'completion_blocked'::"text", 'already_dispatched'::"text"]))),
    CONSTRAINT "dispatch_completion_evidence_status_check" CHECK (("evidence_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'rejected'::"text", 'blocked'::"text", 'released'::"text"]))),
    CONSTRAINT "dispatch_completion_evidence_type_check" CHECK (("evidence_type" = ANY (ARRAY['completion_review'::"text", 'completion_attestation'::"text", 'completion_hold'::"text", 'completion_hold_release'::"text", 'supervisor_override'::"text"])))
);


ALTER TABLE "public"."dispatch_completion_evidence" OWNER TO "postgres";


COMMENT ON TABLE "public"."dispatch_completion_evidence" IS 'Phase 4D append-only dispatch completion governance. Attestation ≠ orders.status dispatched ≠ stock deduct.';



CREATE TABLE IF NOT EXISTS "public"."dispatch_readiness_evidence" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "queue_item_id" "uuid",
    "evidence_type" "text" NOT NULL,
    "evidence_status" "text" NOT NULL,
    "evidence_ref" "text",
    "photo_ref" "text",
    "document_ref" "text",
    "barcode_ref" "text",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dispatch_readiness_evidence_status_check" CHECK (("evidence_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'rejected'::"text", 'missing'::"text", 'expired'::"text"]))),
    CONSTRAINT "dispatch_readiness_evidence_type_check" CHECK (("evidence_type" = ANY (ARRAY['packing_photo'::"text", 'carton_barcode'::"text", 'gate_scan'::"text", 'reservation_check'::"text", 'finance_signal'::"text", 'document_placeholder'::"text", 'manual_readiness_review'::"text"])))
);


ALTER TABLE "public"."dispatch_readiness_evidence" OWNER TO "postgres";


COMMENT ON TABLE "public"."dispatch_readiness_evidence" IS 'Phase 4B append-only dispatch readiness evidence. Gate eligibility only — not dispatch completion.';



CREATE TABLE IF NOT EXISTS "public"."dispatch_release_lineage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "previous_status" "text" NOT NULL,
    "next_status" "text" NOT NULL,
    "release_reason" "text",
    "release_type" "text" NOT NULL,
    "transporter_reference" "text",
    "gate_reference" "text",
    "completion_reference" "text",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "override_reason" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dispatch_release_lineage_type_check" CHECK (("release_type" = ANY (ARRAY['finalize'::"text", 'reversal'::"text", 'stock_confirmation'::"text", 'stock_reversal'::"text", 'customer_publication'::"text", 'transport_handoff'::"text", 'override'::"text"])))
);


ALTER TABLE "public"."dispatch_release_lineage" OWNER TO "postgres";


COMMENT ON TABLE "public"."dispatch_release_lineage" IS 'Phase 4E append-only dispatch release lineage. Governed orders.status mutation is auditable via correlation_id.';



CREATE TABLE IF NOT EXISTS "public"."dispatches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "dispatch_number" "text",
    "status" "text",
    "dispatch_date" "date",
    "transporter_name" "text",
    "driver_name" "text",
    "driver_phone" "text",
    "tracking_number" "text",
    "company_id" "uuid",
    "proof_storage_path" "text",
    "is_partial" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."dispatches" OWNER TO "postgres";


COMMENT ON COLUMN "public"."dispatches"."proof_storage_path" IS 'Storage path in receipts bucket (dispatch proof of handover)';



COMMENT ON COLUMN "public"."dispatches"."is_partial" IS 'True when this row records a partial shipment; order must not be closed from this row alone at security gate';



CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "dispatch_id" "uuid",
    "type" "text",
    "file_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "company_id" "uuid"
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_performance_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "total_handled" integer DEFAULT 0,
    "avg_rating" numeric DEFAULT 0,
    "sla_compliance_pct" numeric DEFAULT 100,
    "total_penalty_score" integer DEFAULT 0,
    "never_responded_count" integer DEFAULT 0,
    "period_start" "date" DEFAULT ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))::"date" NOT NULL,
    "period_end" "date" DEFAULT ((("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone) + '1 mon'::interval) - '1 day'::interval))::"date" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."employee_performance_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exchange_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "base_currency" "text" NOT NULL,
    "target_currency" "text" NOT NULL,
    "exchange_rate" numeric(18,6) NOT NULL,
    "source_type" "text" DEFAULT 'manual'::"text",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."exchange_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."factory_holidays" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "holiday_date" "date" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."factory_holidays" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."factory_inventory" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "quantity" numeric DEFAULT 0,
    "last_updated" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."factory_inventory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."finance_review_evidence" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "review_type" "text" NOT NULL,
    "review_status" "text" NOT NULL,
    "evidence_type" "text" NOT NULL,
    "evidence_ref" "text",
    "utr_ref" "text",
    "amount" numeric,
    "currency" "text",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "override_reason" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "finance_review_evidence_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'rejected'::"text", 'blocked'::"text", 'released'::"text"]))),
    CONSTRAINT "finance_review_evidence_type_check" CHECK (("review_type" = ANY (ARRAY['advance_verification'::"text", 'credit_review'::"text", 'finance_hold'::"text", 'commercial_release'::"text", 'override_review'::"text"])))
);


ALTER TABLE "public"."finance_review_evidence" OWNER TO "postgres";


COMMENT ON TABLE "public"."finance_review_evidence" IS 'Phase 4C append-only finance review evidence. Commercial release ≠ invoiced ≠ dispatched.';



CREATE TABLE IF NOT EXISTS "public"."freight_ledger" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "transporter_name" "text",
    "total_freight_amt" numeric DEFAULT 0,
    "advance_paid_amt" numeric DEFAULT 0,
    "balance_due_amt" numeric GENERATED ALWAYS AS (("total_freight_amt" - "advance_paid_amt")) STORED,
    "payment_status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "freight_ledger_payment_status_check" CHECK (("payment_status" = ANY (ARRAY['pending'::"text", 'partially_paid'::"text", 'paid'::"text"])))
);


ALTER TABLE "public"."freight_ledger" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."identity_profiles" (
    "user_id" "uuid" NOT NULL,
    "identity_class" "text" DEFAULT 'staff'::"text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "display_name" "text",
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "identity_profiles_identity_class_check" CHECK (("identity_class" = ANY (ARRAY['staff'::"text", 'customer'::"text", 'service'::"text", 'device'::"text"]))),
    CONSTRAINT "identity_profiles_status_check" CHECK (("status" = ANY (ARRAY['invited'::"text", 'pending_approval'::"text", 'active'::"text", 'suspended'::"text", 'disabled'::"text"])))
);


ALTER TABLE "public"."identity_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_adjustments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "adjustment_type" "text",
    "quantity" numeric,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_adjustments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "current_stock" numeric(10,2) DEFAULT 0,
    "min_threshold" numeric(10,2) DEFAULT 0,
    "unit" "text" NOT NULL,
    "last_restocked" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_movements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "movement_type" "text" NOT NULL,
    "reservation_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "sku" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "source_location" "text",
    "destination_location" "text",
    "actor_id" "uuid",
    "reason_code" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_movements_type_check" CHECK (("movement_type" = ANY (ARRAY['reservation_created'::"text", 'reservation_adjusted'::"text", 'reservation_released'::"text", 'reservation_expired'::"text", 'reservation_fulfilled'::"text", 'inventory_hold'::"text", 'inventory_unhold'::"text", 'dispatch_consumption_confirmed'::"text", 'dispatch_consumption_reversed'::"text", 'stock_variance_recorded'::"text", 'stock_quarantined'::"text", 'stock_quarantine_released'::"text"])))
);


ALTER TABLE "public"."inventory_movements" OWNER TO "postgres";


COMMENT ON TABLE "public"."inventory_movements" IS 'Append-only inventory movement ledger. UPDATE/DELETE blocked.';



CREATE TABLE IF NOT EXISTS "public"."inventory_reservation_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reservation_id" "uuid" NOT NULL,
    "inventory_entity_type" "text" NOT NULL,
    "inventory_entity_id" "uuid" NOT NULL,
    "allocated_qty" numeric NOT NULL,
    "allocation_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "allocated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_reservation_allocations_allocated_qty_check" CHECK (("allocated_qty" > (0)::numeric)),
    CONSTRAINT "inventory_reservation_allocations_status_check" CHECK (("allocation_status" = ANY (ARRAY['active'::"text", 'released'::"text", 'expired'::"text", 'fulfilled'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."inventory_reservation_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_reservations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reservation_number" "text" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "queue_item_id" "uuid",
    "customer_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "sku" "text" NOT NULL,
    "requested_qty" numeric NOT NULL,
    "reserved_qty" numeric DEFAULT 0 NOT NULL,
    "fulfilled_qty" numeric DEFAULT 0 NOT NULL,
    "released_qty" numeric DEFAULT 0 NOT NULL,
    "reservation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reservation_priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "source_department" "text",
    "reserved_by" "uuid",
    "approved_by" "uuid",
    "expires_at" timestamp with time zone,
    "notes" "text",
    "correlation_id" "text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_reservations_fulfilled_qty_check" CHECK (("fulfilled_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_reservations_priority_check" CHECK (("reservation_priority" = ANY (ARRAY['low'::"text", 'normal'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "inventory_reservations_qty_coherent" CHECK (((("reserved_qty" + "fulfilled_qty") + "released_qty") <= ("requested_qty" + 0.0001))),
    CONSTRAINT "inventory_reservations_released_qty_check" CHECK (("released_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_reservations_requested_qty_check" CHECK (("requested_qty" > (0)::numeric)),
    CONSTRAINT "inventory_reservations_reserved_qty_check" CHECK (("reserved_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_reservations_status_check" CHECK (("reservation_status" = ANY (ARRAY['pending'::"text", 'reserved'::"text", 'partially_reserved'::"text", 'blocked'::"text", 'released'::"text", 'expired'::"text", 'fulfilled'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."inventory_reservations" OWNER TO "postgres";


COMMENT ON TABLE "public"."inventory_reservations" IS 'Phase 4A governed inventory reservations. Writes via reservation repository only.';



CREATE TABLE IF NOT EXISTS "public"."inventory_stock_balances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "sku" "text" NOT NULL,
    "location_code" "text" NOT NULL,
    "available_qty" numeric DEFAULT 0 NOT NULL,
    "reserved_qty" numeric DEFAULT 0 NOT NULL,
    "damaged_qty" numeric DEFAULT 0 NOT NULL,
    "expired_qty" numeric DEFAULT 0 NOT NULL,
    "quarantine_qty" numeric DEFAULT 0 NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_stock_balances_available_qty_check" CHECK (("available_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_stock_balances_damaged_qty_check" CHECK (("damaged_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_stock_balances_expired_qty_check" CHECK (("expired_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_stock_balances_quarantine_qty_check" CHECK (("quarantine_qty" >= (0)::numeric)),
    CONSTRAINT "inventory_stock_balances_reserved_qty_check" CHECK (("reserved_qty" >= (0)::numeric))
);


ALTER TABLE "public"."inventory_stock_balances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dispatch_id" "uuid",
    "invoice_number" "text",
    "invoice_value" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."invoices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inward_material_advice" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text",
    "company_id" "uuid",
    "sales_exec_id" "uuid",
    "reason" "text",
    "expected_value" numeric DEFAULT 0,
    "status" "text" DEFAULT 'expected'::"text",
    "accompanying_docs" "text",
    "gate_entry_id" "uuid",
    "is_defect" boolean DEFAULT false,
    "fault_department" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "fault_attribution" "text",
    "settlement_value" numeric DEFAULT 0,
    "settled_by" "uuid",
    "settled_at" timestamp with time zone,
    CONSTRAINT "inward_material_advice_status_check" CHECK (("status" = ANY (ARRAY['expected'::"text", 'at_gate'::"text", 'under_inspection'::"text", 'settled'::"text"]))),
    CONSTRAINT "inward_material_advice_type_check" CHECK (("type" = ANY (ARRAY['sales_return'::"text", 'purchase_inward'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."inward_material_advice" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inward_material_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "advice_id" "uuid",
    "product_id" "uuid",
    "expected_qty" integer,
    "received_qty" integer DEFAULT 0
);


ALTER TABLE "public"."inward_material_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ledger_disputes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ledger_id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "raised_via" "text" DEFAULT 'whatsapp'::"text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "resolution_notes" "text",
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ledger_disputes_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'investigating'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."ledger_disputes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."moq_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rule_scope" "text" NOT NULL,
    "product_id" "uuid",
    "category_id" "uuid",
    "carton_type" "text",
    "pack_size" "text",
    "customer_type" "text",
    "min_quantity" numeric(12,2),
    "validation_mode" "text" DEFAULT 'hard_stop'::"text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."moq_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_key" "text" NOT NULL,
    "event_name" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true,
    "priority" "text" DEFAULT 'normal'::"text",
    "channels" "text"[] DEFAULT '{email}'::"text"[],
    "template_body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "notification_events_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'normal'::"text", 'high'::"text", 'critical'::"text"])))
);


ALTER TABLE "public"."notification_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "type" "text",
    "message" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_read" boolean DEFAULT false,
    "user_id" "uuid"
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "action" "text",
    "entity_type" "text",
    "entity_id" "uuid",
    "user_id" "uuid",
    "details" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_carton_contents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "carton_id" "uuid" NOT NULL,
    "production_label_id" "uuid",
    "manual_sku" "text",
    "manual_qty" numeric,
    "manual_reason" "text",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_carton_contents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_cartons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "carton_no" "text" NOT NULL,
    "order_ref" "text",
    "customer_code" "text",
    "customer_name" "text",
    "carton_index" integer,
    "carton_total" integer,
    "packed_by" "uuid",
    "packed_at" timestamp with time zone,
    "gross_weight" numeric,
    "net_weight" numeric,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "remarks" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_cartons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_departments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "kind" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_departments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_dispatch_document_bundles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dpl_id" "uuid",
    "pi_id" "uuid",
    "invoice_ref" "text",
    "eway_ref" "text",
    "transport_ref" "text",
    "gate_pass_no" "text",
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_dispatch_document_bundles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_dpl_cartons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dpl_id" "uuid" NOT NULL,
    "carton_id" "uuid" NOT NULL,
    "position" integer
);


ALTER TABLE "public"."ols_dpl_cartons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_dpl_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dpl_no" "text" NOT NULL,
    "order_ref" "text",
    "customer_name" "text",
    "destination" "text",
    "transport_mode" "text",
    "prepared_by" "uuid",
    "prepared_at" timestamp with time zone DEFAULT "now"(),
    "total_cartons" integer,
    "total_gross" numeric,
    "total_net" numeric,
    "remarks" "text",
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_dpl_documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_finance_pi" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pi_no" "text" NOT NULL,
    "dpl_id" "uuid",
    "order_ref" "text",
    "customer_name" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "cleared_at" timestamp with time zone,
    "invoice_ref" "text",
    "tally_invoice_no" "text",
    "tally_sync_status" "text",
    "eway_bill_no" "text",
    "eway_status" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_finance_pi" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_finance_pi_cartons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pi_id" "uuid" NOT NULL,
    "carton_id" "uuid" NOT NULL
);


ALTER TABLE "public"."ols_finance_pi_cartons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_finance_pi_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pi_id" "uuid" NOT NULL,
    "sku" "text",
    "product_name" "text",
    "quantity" numeric,
    "net_weight" numeric,
    "gross_weight" numeric
);


ALTER TABLE "public"."ols_finance_pi_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_gate_scans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "qr_ref" "text",
    "shipping_label_id" "uuid",
    "result" "text",
    "reason" "text",
    "scanned_by" "uuid",
    "scanned_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ols_gate_scans_result_check" CHECK (("result" = ANY (ARRAY['green'::"text", 'red'::"text"])))
);


ALTER TABLE "public"."ols_gate_scans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_inventory_movements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "production_label_id" "uuid",
    "from_location" "text",
    "to_location" "text",
    "movement_type" "text",
    "reference_no" "text",
    "user_id" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_inventory_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_label_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "label_type" "text" NOT NULL,
    "width_mm" numeric NOT NULL,
    "height_mm" numeric NOT NULL,
    "barcode_type" "text" DEFAULT 'CODE128'::"text",
    "show_qr" boolean DEFAULT false,
    "font_scale" numeric DEFAULT 1.0,
    "fields" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_label_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_manual_override_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ref_type" "text",
    "ref_id" "uuid",
    "reason" "text",
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_manual_override_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_orders_cache" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "external_ref" "text",
    "order_number" "text" NOT NULL,
    "customer_code" "text",
    "customer_name" "text",
    "destination" "text",
    "transport_mode" "text",
    "status" "text" DEFAULT 'open'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_orders_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role" "text" NOT NULL,
    "module" "text" NOT NULL,
    "can_view" boolean DEFAULT false,
    "can_create" boolean DEFAULT false,
    "can_edit" boolean DEFAULT false,
    "can_delete" boolean DEFAULT false,
    "can_approve" boolean DEFAULT false
);


ALTER TABLE "public"."ols_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_print_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid",
    "printer_id" "uuid",
    "command_lang" "text",
    "command_payload" "text",
    "status" "text" DEFAULT 'queued'::"text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_print_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_print_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ref_type" "text",
    "ref_id" "uuid",
    "printer_id" "uuid",
    "printed_by" "uuid",
    "is_reprint" boolean DEFAULT false,
    "reprint_count" integer DEFAULT 0,
    "reason" "text",
    "success" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_print_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_printer_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "printer_id" "uuid" NOT NULL,
    "darkness" integer DEFAULT 8,
    "speed" integer DEFAULT 4,
    "width_mm" numeric DEFAULT 100,
    "height_mm" numeric DEFAULT 50,
    "gap_mm" numeric DEFAULT 3,
    "black_mark_offset_mm" numeric DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_printer_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_printers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "model" "text",
    "command_lang" "text",
    "location" "text",
    "status" "text" DEFAULT 'online'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ols_printers_command_lang_check" CHECK (("command_lang" = ANY (ARRAY['TSPL'::"text", 'ZPL'::"text", 'BROWSER'::"text"])))
);


ALTER TABLE "public"."ols_printers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_production_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_no" "text" NOT NULL,
    "product_id" "uuid",
    "department_id" "uuid",
    "shift" "text",
    "mfg_date" "date",
    "shelf_life_days" integer,
    "qc_status" "text" DEFAULT 'pending'::"text",
    "remarks" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_production_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_production_labels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "label_no" "text" NOT NULL,
    "batch_id" "uuid",
    "product_id" "uuid",
    "department_id" "uuid",
    "tray_serial" "text",
    "net_weight" numeric,
    "gross_weight" numeric,
    "mfg_date" "date",
    "best_before" "date",
    "qc_status" "text" DEFAULT 'pending'::"text",
    "operator_name" "text",
    "status" "text" DEFAULT 'active'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_production_labels" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_products_cache" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "external_ref" "text",
    "sku" "text",
    "name" "text" NOT NULL,
    "category" "text",
    "default_net_weight" numeric,
    "default_gross_weight" numeric,
    "shelf_life_days" integer,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_products_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_profiles_light" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "full_name" "text",
    "email" "text",
    "default_role" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_profiles_light" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_reprint_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ref_type" "text",
    "ref_id" "uuid",
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "requested_by" "uuid",
    "approved_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_reprint_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_scan_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scan_value" "text",
    "scan_context" "text",
    "user_id" "uuid",
    "result" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_scan_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "key" "text" NOT NULL,
    "value" "jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_shipping_labels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shipping_no" "text" NOT NULL,
    "carton_id" "uuid",
    "pi_id" "uuid",
    "consignor" "text",
    "consignee" "text",
    "address" "text",
    "phone" "text",
    "invoice_ref" "text",
    "eway_ref" "text",
    "transport_ref" "text",
    "route" "text",
    "handling_marks" "text",
    "qr_ref" "text",
    "status" "text" DEFAULT 'printed'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_shipping_labels" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ols_stock_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "production_label_id" "uuid",
    "current_location" "text" DEFAULT 'store'::"text",
    "current_status" "text" DEFAULT 'in_stock'::"text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ols_stock_units" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."operational_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "customer_id" "uuid",
    "queue_item_id" "uuid",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "visibility" "text" DEFAULT 'internal'::"text" NOT NULL,
    "severity" "text" DEFAULT 'info'::"text" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text",
    "reason_code" "text",
    "reason_text" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "correlation_id" "text" NOT NULL,
    "idempotency_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_application" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "event_version" integer DEFAULT 1 NOT NULL,
    "command_name" "text",
    "command_id" "text",
    "causation_id" "text",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payload_fingerprint" "text" NOT NULL,
    CONSTRAINT "operational_events_event_version_positive" CHECK (("event_version" > 0)),
    CONSTRAINT "operational_events_payload_fingerprint_nonempty" CHECK (("btrim"("payload_fingerprint") <> ''::"text")),
    CONSTRAINT "operational_events_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'urgent'::"text", 'critical'::"text"]))),
    CONSTRAINT "operational_events_source_application_nonempty" CHECK (("btrim"("source_application") <> ''::"text")),
    CONSTRAINT "operational_events_visibility_check" CHECK (("visibility" = ANY (ARRAY['internal'::"text", 'public_candidate'::"text", 'staff_only'::"text"])))
);


ALTER TABLE "public"."operational_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."operational_events" IS 'Phase 3D append-only operational event store. UPDATE/DELETE blocked by trigger and REVOKE.';



CREATE TABLE IF NOT EXISTS "public"."operational_queue_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "queue_item_id" "uuid" NOT NULL,
    "from_user_id" "uuid",
    "to_user_id" "uuid",
    "from_department" "text",
    "to_department" "text",
    "reason" "text",
    "assigned_by" "uuid",
    "assigned_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."operational_queue_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."operational_queue_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "queue_type" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "customer_id" "uuid",
    "title" "text" NOT NULL,
    "summary" "text",
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "state" "text" DEFAULT 'pending'::"text" NOT NULL,
    "owner_department" "text",
    "assigned_to" "uuid",
    "escalation_level" "text" DEFAULT 'none'::"text" NOT NULL,
    "blocker_code" "text",
    "blocker_summary" "text",
    "sla_due_at" timestamp with time zone,
    "source" "text" DEFAULT 'execution_os'::"text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    CONSTRAINT "operational_queue_items_escalation_level_check" CHECK (("escalation_level" = ANY (ARRAY['none'::"text", 'tier1'::"text", 'tier2'::"text", 'tier3'::"text", 'cmd'::"text"]))),
    CONSTRAINT "operational_queue_items_state_check" CHECK (("state" = ANY (ARRAY['pending'::"text", 'acknowledged'::"text", 'assigned'::"text", 'in_progress'::"text", 'blocked'::"text", 'escalated'::"text", 'completed'::"text", 'failed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."operational_queue_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."operational_queue_items" IS 'Phase 3A durable work queue items. Lifecycle writes must emit operational_events.';



CREATE TABLE IF NOT EXISTS "public"."operational_scan_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scan_type" "text" NOT NULL,
    "verification_type" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "queue_item_id" "uuid",
    "barcode_value" "text" NOT NULL,
    "expected_barcode" "text",
    "verification_status" "text" NOT NULL,
    "mismatch_reason" "text",
    "scan_source" "text" NOT NULL,
    "scan_device_id" "text",
    "actor_id" "uuid",
    "actor_role" "text",
    "actor_department" "text",
    "photo_evidence_url" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "correlation_id" "text" NOT NULL,
    "idempotency_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_scan_records_scan_type_check" CHECK (("scan_type" = ANY (ARRAY['order'::"text", 'carton'::"text", 'department_handoff'::"text", 'ready_goods_intake'::"text", 'dispatch_gate'::"text", 'assembly_handoff'::"text"]))),
    CONSTRAINT "operational_scan_records_verification_status_check" CHECK (("verification_status" = ANY (ARRAY['scanned'::"text", 'verified'::"text", 'mismatch'::"text", 'duplicate'::"text", 'rejected'::"text", 'escalated'::"text"]))),
    CONSTRAINT "operational_scan_records_verification_type_check" CHECK (("verification_type" = ANY (ARRAY['identity_match'::"text", 'gate_check'::"text", 'handoff_check'::"text", 'intake_check'::"text"])))
);


ALTER TABLE "public"."operational_scan_records" OWNER TO "postgres";


COMMENT ON TABLE "public"."operational_scan_records" IS 'Phase 3C append-only barcode scan evidence. UPDATE/DELETE blocked by trigger and REVOKE.';



CREATE TABLE IF NOT EXISTS "public"."operational_search_index" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "customer_id" "uuid",
    "queue_item_id" "uuid",
    "scan_record_id" "uuid",
    "event_id" "uuid",
    "public_ref" "text",
    "search_title" "text" NOT NULL,
    "search_subtitle" "text",
    "search_body" "text",
    "normalized_tokens" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "aliases" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "barcode_values" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "so_numbers" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "phone_tokens" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "email_tokens" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "department" "text",
    "visibility" "text" DEFAULT 'internal'::"text" NOT NULL,
    "sensitivity" "text" DEFAULT 'normal'::"text" NOT NULL,
    "source" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_search_index_sensitivity_check" CHECK (("sensitivity" = ANY (ARRAY['normal'::"text", 'restricted'::"text", 'confidential'::"text"]))),
    CONSTRAINT "operational_search_index_visibility_check" CHECK (("visibility" = ANY (ARRAY['internal'::"text", 'staff_scoped'::"text", 'customer_safe_candidate'::"text"])))
);


ALTER TABLE "public"."operational_search_index" OWNER TO "postgres";


COMMENT ON TABLE "public"."operational_search_index" IS 'Phase 3I governed operational search index. Internal staff only; no customer/public search.';



CREATE TABLE IF NOT EXISTS "public"."order_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "file_url" "text" NOT NULL,
    "attachment_type" "text" DEFAULT 'packing_proof'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "product_id" "uuid",
    "quantity" numeric DEFAULT 0 NOT NULL,
    "pack_size" "text",
    "carton_type" "text",
    "notes" "text",
    "department" "text",
    "production_status" "text" DEFAULT 'pending'::"text",
    "task_type" "text" DEFAULT 'customer'::"text",
    "actual_packed_qty" integer,
    "weight_kg" numeric
);


ALTER TABLE "public"."order_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "company_id" "uuid",
    "payment_type" "text" NOT NULL,
    "amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "payment_date" "date" DEFAULT CURRENT_DATE,
    "reference_no" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "proof_url" "text",
    "proof_storage_path" "text",
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "status" "text" DEFAULT 'uploaded'::"text",
    "rejection_reason" "text",
    CONSTRAINT "order_payments_payment_type_check" CHECK (("payment_type" = ANY (ARRAY['advance'::"text", 'balance'::"text", 'adjustment'::"text"])))
);


ALTER TABLE "public"."order_payments" OWNER TO "postgres";


COMMENT ON COLUMN "public"."order_payments"."payment_type" IS 'advance | balance | rescue | refund';



COMMENT ON COLUMN "public"."order_payments"."proof_url" IS 'Public URL of payment receipt from Supabase receipts bucket';



COMMENT ON COLUMN "public"."order_payments"."proof_storage_path" IS 'Internal storage path for payment proof in receipts bucket';



COMMENT ON COLUMN "public"."order_payments"."verified_by" IS 'UUID of finance executive who verified this payment proof';



COMMENT ON COLUMN "public"."order_payments"."verified_at" IS 'Timestamp when finance verified the proof';



COMMENT ON COLUMN "public"."order_payments"."status" IS 'Payment proof status: uploaded | verified | rejected';



COMMENT ON COLUMN "public"."order_payments"."rejection_reason" IS 'If rejected, reason for rejection (missing details, invalid UTR, etc)';



CREATE TABLE IF NOT EXISTS "public"."order_returns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "product_id" "uuid",
    "quantity_returned" integer NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "logged_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "inspection_notes" "text",
    "original_value" numeric DEFAULT 0,
    "final_credit_value" numeric DEFAULT 0,
    "loss_amount" numeric GENERATED ALWAYS AS (("original_value" - "final_credit_value")) STORED,
    "admin_approval" boolean DEFAULT false,
    "is_manufacturing_defect" boolean DEFAULT false,
    "defect_details" "text",
    "gate_entry_logged_at" timestamp with time zone,
    CONSTRAINT "order_returns_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'received_at_factory'::"text", 'inspected'::"text", 'credited'::"text"])))
);


ALTER TABLE "public"."order_returns" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_status_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "changed_by" "uuid",
    "old_status" "text",
    "new_status" "text",
    "changed_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."order_status_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "sales_order_value" numeric DEFAULT 0,
    "advance_required" numeric DEFAULT 0,
    "advance_paid" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "payment_status" "text" DEFAULT 'unpaid'::"text",
    "closed_at" timestamp with time zone,
    "closed_by" "uuid",
    "is_export" boolean DEFAULT false,
    "port_of_discharge" "text",
    "country_of_origin" "text" DEFAULT 'India'::"text",
    "document_stage" "text" DEFAULT 'SO'::"text",
    "payment_cleared" boolean DEFAULT false,
    "eway_bill_number" "text",
    "payment_receipt_url" "text",
    "estimated_despatch_date" "date",
    "actual_despatch_date" "date",
    "tracking_number" "text",
    "courier_name" "text",
    "proforma_invoice_url" "text",
    "final_invoice_url" "text",
    "eway_bill_url" "text",
    "requested_dispatch_date" "date",
    "dispatch_urgency" "text" DEFAULT 'standard'::"text",
    "admin_promised_date" "date",
    "system_estimated_date" "date",
    "gate_pass_number" "text",
    "tracking_token" "text",
    "is_starter_pack" boolean DEFAULT false NOT NULL,
    "total_weight_kg" numeric,
    "parser_confidence" numeric,
    "needs_clarification" boolean DEFAULT false NOT NULL,
    "is_waste" boolean DEFAULT false NOT NULL,
    "wamid" "text",
    "is_duplicate" boolean DEFAULT false NOT NULL,
    "duplicate_of_order_id" "uuid",
    "order_number" "text" NOT NULL,
    "finance_verified_by" "uuid",
    "finance_verified_at" timestamp with time zone,
    "payment_rejection_reason" "text"
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."orders"."is_starter_pack" IS 'True when the draft was created via Growth Intelligence Starter Builder. Cart waives carton-fill / MOQ enforcement for these orders so Grand Total exactly matches the displayed Estimated Investment.';



COMMENT ON COLUMN "public"."orders"."order_number" IS 'Human-readable sales order reference SO-YYYY-NNNNNN (unique).';



COMMENT ON COLUMN "public"."orders"."finance_verified_by" IS 'UUID of finance executive who verified payment or approved credit';



COMMENT ON COLUMN "public"."orders"."finance_verified_at" IS 'Timestamp when finance cleared this order for operations';



COMMENT ON COLUMN "public"."orders"."payment_rejection_reason" IS 'Latest finance rejection message when payment is sent back to awaiting_receipt; cleared when buyer uploads a new receipt or finance verifies/credits.';



CREATE TABLE IF NOT EXISTS "public"."org_branches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "branch_code" "text",
    "name" "text" NOT NULL,
    "branch_type" "text" DEFAULT 'operating'::"text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "org_branches_branch_type_check" CHECK (("branch_type" = ANY (ARRAY['registered'::"text", 'billing'::"text", 'shipping'::"text", 'operating'::"text", 'warehouse'::"text", 'outlet'::"text"]))),
    CONSTRAINT "org_branches_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'suspended'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."org_branches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "legal_name" "text" NOT NULL,
    "display_name" "text",
    "external_ref" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "org_companies_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'suspended'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."org_companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid",
    "full_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "org_contacts_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'suspended'::"text", 'inactive'::"text"])))
);


ALTER TABLE "public"."org_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_membership_branch_scopes" (
    "membership_id" "uuid" NOT NULL,
    "branch_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."org_membership_branch_scopes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_membership_roles" (
    "membership_id" "uuid" NOT NULL,
    "role_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."org_membership_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "contact_id" "uuid",
    "user_id" "uuid",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "valid_until" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "org_memberships_check" CHECK ((("contact_id" IS NOT NULL) OR ("user_id" IS NOT NULL))),
    CONSTRAINT "org_memberships_check1" CHECK ((("valid_until" IS NULL) OR ("valid_until" > "valid_from"))),
    CONSTRAINT "org_memberships_status_check" CHECK (("status" = ANY (ARRAY['invited'::"text", 'pending_approval'::"text", 'active'::"text", 'suspended'::"text", 'ended'::"text"])))
);


ALTER TABLE "public"."org_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."packing_lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dispatch_id" "uuid",
    "product_id" "uuid",
    "packed_quantity" numeric DEFAULT 0 NOT NULL,
    "order_item_id" "uuid",
    "pack_size" "text",
    "carton_type" "text"
);


ALTER TABLE "public"."packing_lists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "permission_key" "text" NOT NULL,
    "module_name" "text" NOT NULL,
    "permission_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."portal_access_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "application_id" "uuid",
    "company_id" "uuid",
    "invite_email" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "sent_at" timestamp with time zone,
    "accepted_at" timestamp with time zone,
    "notes" "text"
);


ALTER TABLE "public"."portal_access_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."premium_announcements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "subtitle" "text",
    "image_url" "text",
    "video_url" "text",
    "priority" "text" DEFAULT 'greeting'::"text" NOT NULL,
    "target_audience" "text" DEFAULT 'all'::"text" NOT NULL,
    "target_region" "text",
    "display_duration" integer DEFAULT 8 NOT NULL,
    "trigger_delay" integer DEFAULT 10 NOT NULL,
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone,
    "is_active" boolean DEFAULT true NOT NULL,
    "cta_text" "text",
    "cta_link" "text",
    "view_count" integer DEFAULT 0 NOT NULL,
    "skip_count" integer DEFAULT 0 NOT NULL,
    "completion_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "premium_announcements_display_duration_check" CHECK ((("display_duration" >= 6) AND ("display_duration" <= 30))),
    CONSTRAINT "premium_announcements_priority_check" CHECK (("priority" = ANY (ARRAY['critical'::"text", 'offer'::"text", 'launch'::"text", 'greeting'::"text"]))),
    CONSTRAINT "premium_announcements_target_audience_check" CHECK (("target_audience" = ANY (ARRAY['all'::"text", 'new'::"text", 'region'::"text"]))),
    CONSTRAINT "premium_announcements_trigger_delay_check" CHECK ((("trigger_delay" >= 0) AND ("trigger_delay" <= 60)))
);


ALTER TABLE "public"."premium_announcements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pricing_slabs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slab_name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."pricing_slabs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_aliases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alias_text" "text" NOT NULL,
    "canonical_name" "text" NOT NULL,
    "product_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_aliases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_bom" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "component_product_id" "uuid",
    "component_name" "text",
    "quantity_per_unit" numeric DEFAULT 1 NOT NULL,
    "source_department" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bom_type" "text" DEFAULT 'internal_bom'::"text" NOT NULL,
    CONSTRAINT "product_bom_bom_type_check" CHECK (("bom_type" = ANY (ARRAY['internal_bom'::"text", 'hamper_bom'::"text"])))
);


ALTER TABLE "public"."product_bom" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_media" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "file_url" "text" NOT NULL,
    "type" "text",
    "status" "text" DEFAULT 'raw'::"text",
    "angle" "text",
    "alt_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_media" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_moq_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "channel" "text" NOT NULL,
    "customer_type" "text",
    "moq_applicable" boolean DEFAULT false NOT NULL,
    "allow_override" boolean DEFAULT false NOT NULL,
    "moq_value" numeric,
    "moq_uom" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "min_carton_qty" numeric,
    "carton_logic" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_moq_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_pricing_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "price_channel" "text" NOT NULL,
    "price_type" "text" DEFAULT 'quotation_based'::"text" NOT NULL,
    "base_price" numeric,
    "discount_percent" numeric,
    "calculated_price" numeric,
    "currency" "text" DEFAULT 'INR'::"text" NOT NULL,
    "uom" "text",
    "gst_rate" numeric,
    "tax_inclusive" boolean DEFAULT false NOT NULL,
    "source" "text" DEFAULT 'catalogue_local'::"text" NOT NULL,
    "approval_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "valid_from" "date",
    "valid_until" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_pricing_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_tag_mapping" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "tag_id" "uuid",
    "manual_sort_index" integer DEFAULT 0
);


ALTER TABLE "public"."product_tag_mapping" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tag_key" "text" NOT NULL,
    "tag_label" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."product_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "variant_name" "text" NOT NULL,
    "price" numeric DEFAULT 0 NOT NULL,
    "moq" integer DEFAULT 1 NOT NULL,
    "sku" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_variants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."production_issues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "department" "text" NOT NULL,
    "issue_type" "text" NOT NULL,
    "comment" "text",
    "photo_url" "text",
    "reported_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "production_issues_issue_type_check" CHECK (("issue_type" = ANY (ARRAY['material'::"text", 'machine'::"text", 'delay'::"text"])))
);


ALTER TABLE "public"."production_issues" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."production_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_item_id" "uuid",
    "order_id" "uuid",
    "product_id" "uuid",
    "department" "text" NOT NULL,
    "assigned_to" "uuid",
    "assigned_qty" numeric DEFAULT 0 NOT NULL,
    "produced_qty" numeric DEFAULT 0,
    "wasted_qty" numeric DEFAULT 0,
    "net_weight_per_unit" numeric DEFAULT 0,
    "batch_number" "text",
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "stage" "text" DEFAULT 'prep'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "rejection_reason" "text",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "locked" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "production_jobs_priority_check" CHECK (("priority" = ANY (ARRAY['normal'::"text", 'urgent'::"text", 'red'::"text"]))),
    CONSTRAINT "production_jobs_stage_check" CHECK (("stage" = ANY (ARRAY['prep'::"text", 'processing'::"text", 'finishing'::"text", 'ready'::"text"]))),
    CONSTRAINT "production_jobs_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'rejected'::"text", 'in_production'::"text", 'paused'::"text", 'completed'::"text", 'transferred'::"text"])))
);


ALTER TABLE "public"."production_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."production_pauses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "comment" "text",
    "paused_at" timestamp with time zone DEFAULT "now"(),
    "resumed_at" timestamp with time zone,
    "paused_by" "uuid",
    CONSTRAINT "production_pauses_reason_check" CHECK (("reason" = ANY (ARRAY['machine_breakdown'::"text", 'material_shortage'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."production_pauses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."production_rgs_transfers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "product_id" "uuid",
    "quantity" numeric DEFAULT 0 NOT NULL,
    "batch_number" "text",
    "transferred_by" "uuid",
    "rgs_notified" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."production_rgs_transfers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "category_id" "uuid",
    "price_per_kg" numeric DEFAULT 0,
    "pack_size" "text",
    "carton_type" "text",
    "storage_type" "text",
    "description" "text",
    "shelf_life" "text",
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    "category" "text" NOT NULL,
    "sku" "text" NOT NULL,
    "mrp" numeric,
    "wholesale_price" numeric,
    "weight_per_pc_grams" numeric,
    "net_weight_grams" numeric,
    "moq" numeric DEFAULT 1,
    "packs_per_master_carton" numeric,
    "hsn_code" "text" NOT NULL,
    "gst_percentage" numeric,
    "dietary_tags" "text"[],
    "sub_category" "text",
    "department" "text",
    "base_price" numeric DEFAULT 0,
    "price_bulk" numeric DEFAULT 0,
    "price_wholesale" numeric DEFAULT 0,
    "price_horeca" numeric DEFAULT 0,
    "price_b2b" numeric DEFAULT 0,
    "price_special" numeric DEFAULT 0,
    "uom" "text" DEFAULT 'Pack'::"text",
    "avg_weight_per_pc" numeric,
    "avg_weight_per_pack" numeric,
    "packs_per_carton" numeric,
    "moq_packs" numeric DEFAULT 1,
    "private_label_moq" numeric,
    "private_label_price" numeric,
    "nutrition_facts" "text",
    "mrp_per_pc" numeric,
    "festival_tags" "text",
    "pcs_per_master_carton" numeric,
    "primary_pack_weight_kg" numeric DEFAULT 0 NOT NULL,
    "gst_rate" numeric DEFAULT 5,
    "ingredients" "text",
    "nutritional_info" "jsonb",
    "allergen_warnings" "text",
    "shelf_life_days" integer,
    "gross_weight_grams" integer,
    "storage_instructions" "text",
    "barcode_sku" "text",
    "default_store" "text" DEFAULT 'ready_goods'::"text",
    "production_department" "text",
    "settlement_unit" "text" DEFAULT 'KG'::"text",
    "visible_in_catalog" boolean DEFAULT true NOT NULL,
    "weight_per_box_kg" numeric,
    "grams_per_piece" numeric,
    "aliases" "text"[] DEFAULT '{}'::"text"[],
    "product_family" "text",
    "dimensions" "text",
    "material" "text",
    "gross_weight_kg" numeric,
    "bom_summary" "text",
    "cost_per_pc" numeric DEFAULT 0,
    "cost_per_kg" numeric DEFAULT 0,
    "cost_per_primary_pack" numeric DEFAULT 0,
    "cost_per_master_carton" numeric DEFAULT 0,
    "mrp_per_kg" numeric DEFAULT 0,
    "mrp_per_primary_pack" numeric DEFAULT 0,
    "mrp_per_master_carton" numeric DEFAULT 0,
    "price_b2b_per_pack" numeric DEFAULT 0,
    "price_b2b_per_carton" numeric DEFAULT 0,
    "pcs_per_primary_pack" numeric DEFAULT 0,
    "pcs_per_kg" numeric DEFAULT 0,
    "kg_per_primary_pack" numeric DEFAULT 0,
    "kg_per_master_carton" numeric DEFAULT 0,
    "retail_uom" "text" DEFAULT 'pc'::"text",
    "b2b_uom" "text" DEFAULT 'kg'::"text",
    "bom_required" boolean DEFAULT false NOT NULL,
    "carton_logic" "text",
    "carton_qty" numeric,
    "carton_uom" "text",
    "fixed_carton_required" boolean DEFAULT false,
    "moq_value" numeric,
    "moq_uom" "text",
    "moq_text" "text",
    "primary_uom" "text",
    "pricing_notes" "text",
    "operational_notes" "text",
    "category_code" "text",
    "subcategory_code" "text",
    "division_code" "text",
    "packaging_code" "text",
    "serial_no" numeric,
    "legacy_sku" "text",
    "external_reference_code" "text",
    "product_name" "text",
    "short_name" "text",
    "product_type" "text",
    "product_class" "text",
    "short_description" "text",
    "currency" "text" DEFAULT 'INR'::"text",
    "hero_image_url" "text",
    "label_status" "text" DEFAULT 'draft'::"text",
    "media_status" "text" DEFAULT 'missing'::"text",
    "sku_locked" boolean DEFAULT true,
    "main_department" "text",
    "increment_value" numeric,
    "increment_uom" "text",
    "master_carton_qty" numeric,
    "master_carton_uom" "text",
    "dimension_l_cm" numeric,
    "dimension_w_cm" numeric,
    "dimension_h_cm" numeric,
    "product_dimensions_cm" "text",
    "pcs_per_pack" numeric,
    "pcs_per_carton" numeric,
    "net_weight_g" numeric,
    "gross_weight_g" numeric,
    "private_label_allowed" boolean DEFAULT false,
    "private_label_moq_uom" "text",
    "private_label_cost_per_unit" numeric,
    "private_label_upfront_cost" numeric,
    "customization_allowed" boolean DEFAULT false,
    "customization_note" "text",
    "customization_caution" "text",
    "frozen_shelf_life_days" integer,
    "post_processing_shelf_life_days" integer,
    "temperature_requirement" "text",
    "thawing_instruction" "text",
    "material_type" "text",
    "color_finish_notes" "text",
    "is_catalogue_ready" boolean DEFAULT false,
    "is_sample" boolean DEFAULT false,
    "moq_rule_type" "text",
    "subcategory" "text",
    "unit_conversion_note" "text",
    CONSTRAINT "products_default_store_check" CHECK (("default_store" = ANY (ARRAY['ready_goods'::"text", 'packing_assembly'::"text", '3rd_party'::"text"]))),
    CONSTRAINT "products_production_department_check" CHECK ((("production_department" IS NULL) OR ("production_department" = ANY (ARRAY['arabic_sweets'::"text", 'dragees'::"text", 'fusion_sweets'::"text", 'chocolates_confectionery'::"text", 'seasoned_nuts_mixes'::"text", 'bakery'::"text"])))),
    CONSTRAINT "products_storage_type_check" CHECK (("storage_type" = ANY (ARRAY['ambient'::"text", 'cool'::"text", 'frozen'::"text"])))
);


ALTER TABLE "public"."products" OWNER TO "postgres";


COMMENT ON COLUMN "public"."products"."product_family" IS 'High-level family used for category-aware UI: bulk_sweets | goldware | hampers | retail_pack. Optional — falls back to category inference.';



COMMENT ON COLUMN "public"."products"."dimensions" IS 'Free-text size for non-food items (e.g. "12-inch", "10 x 8 in").';



COMMENT ON COLUMN "public"."products"."material" IS 'Construction material for goldware/packaging (e.g. "Brass", "Acrylic").';



COMMENT ON COLUMN "public"."products"."gross_weight_kg" IS 'Total shipping weight for hampers / gift packs including packaging.';



COMMENT ON COLUMN "public"."products"."bom_summary" IS 'Human-readable summary of included items for hampers (e.g. "2x Asabi 250g, 1x Pyramid 500g").';



CREATE TABLE IF NOT EXISTS "public"."profile_change_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "requested_by" "uuid",
    "field_name" "text" NOT NULL,
    "current_value" "text",
    "requested_value" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "admin_notes" "text",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profile_change_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "company_id" "uuid",
    "full_name" "text",
    "email" "text",
    "role" "text" DEFAULT 'pending_buyer'::"text",
    "department" "text",
    "price_tier" "text",
    "credit_limit" numeric DEFAULT 0,
    "is_approved" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "mobile_number" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."realtime_subscription_contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "schema_name" "text" DEFAULT 'public'::"text" NOT NULL,
    "table_name" "text" NOT NULL,
    "owning_application" "text" NOT NULL,
    "consumer_applications" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "row_filter_required" boolean DEFAULT true NOT NULL,
    "rls_required" boolean DEFAULT true NOT NULL,
    "event_types" "text"[] DEFAULT ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"] NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."realtime_subscription_contracts" OWNER TO "postgres";


COMMENT ON TABLE "public"."realtime_subscription_contracts" IS 'Allow-listed authority for App-Verse Postgres Changes subscriptions.';



CREATE OR REPLACE VIEW "public"."realtime_contract_health" WITH ("security_invoker"='true') AS
 SELECT "c"."schema_name",
    "c"."table_name",
    "c"."owning_application",
    "c"."consumer_applications",
    "c"."enabled",
    "c"."row_filter_required",
    "c"."rls_required",
    (EXISTS ( SELECT 1
           FROM "pg_publication_tables" "p"
          WHERE (("p"."pubname" = 'supabase_realtime'::"name") AND ("p"."schemaname" = "c"."schema_name") AND ("p"."tablename" = "c"."table_name")))) AS "is_published",
    COALESCE("cls"."relrowsecurity", false) AS "rls_enabled",
    (EXISTS ( SELECT 1
           FROM "pg_policies" "pol"
          WHERE (("pol"."schemaname" = "c"."schema_name") AND ("pol"."tablename" = "c"."table_name") AND ("pol"."cmd" = ANY (ARRAY['SELECT'::"text", 'ALL'::"text"]))))) AS "has_read_policy",
        CASE
            WHEN (NOT "c"."enabled") THEN 'disabled'::"text"
            WHEN (NOT (EXISTS ( SELECT 1
               FROM "pg_publication_tables" "p"
              WHERE (("p"."pubname" = 'supabase_realtime'::"name") AND ("p"."schemaname" = "c"."schema_name") AND ("p"."tablename" = "c"."table_name"))))) THEN 'missing_publication'::"text"
            WHEN ("c"."rls_required" AND (NOT COALESCE("cls"."relrowsecurity", false))) THEN 'missing_rls'::"text"
            WHEN ("c"."rls_required" AND (NOT (EXISTS ( SELECT 1
               FROM "pg_policies" "pol"
              WHERE (("pol"."schemaname" = "c"."schema_name") AND ("pol"."tablename" = "c"."table_name") AND ("pol"."cmd" = ANY (ARRAY['SELECT'::"text", 'ALL'::"text"]))))))) THEN 'missing_read_policy'::"text"
            ELSE 'healthy'::"text"
        END AS "health_status"
   FROM (("public"."realtime_subscription_contracts" "c"
     LEFT JOIN "pg_namespace" "ns" ON (("ns"."nspname" = "c"."schema_name")))
     LEFT JOIN "pg_class" "cls" ON ((("cls"."relnamespace" = "ns"."oid") AND ("cls"."relname" = "c"."table_name") AND ("cls"."relkind" = 'r'::"char"))));


ALTER VIEW "public"."realtime_contract_health" OWNER TO "postgres";


COMMENT ON VIEW "public"."realtime_contract_health" IS 'Runtime verification of publication, RLS and read-policy readiness for governed realtime tables.';



CREATE TABLE IF NOT EXISTS "public"."retry_policies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "policy_key" "text" NOT NULL,
    "owning_application" "text" NOT NULL,
    "workload_type" "text" NOT NULL,
    "max_attempts" integer DEFAULT 5 NOT NULL,
    "base_delay_seconds" integer DEFAULT 60 NOT NULL,
    "max_delay_seconds" integer DEFAULT 3600 NOT NULL,
    "backoff_multiplier" numeric(8,3) DEFAULT 2.000 NOT NULL,
    "jitter_percent" integer DEFAULT 10 NOT NULL,
    "dead_letter_enabled" boolean DEFAULT true NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "retry_policies_attempts_check" CHECK ((("max_attempts" >= 1) AND ("max_attempts" <= 50))),
    CONSTRAINT "retry_policies_delay_check" CHECK ((("base_delay_seconds" >= 0) AND ("max_delay_seconds" >= "base_delay_seconds") AND ("max_delay_seconds" <= 604800))),
    CONSTRAINT "retry_policies_jitter_check" CHECK ((("jitter_percent" >= 0) AND ("jitter_percent" <= 100))),
    CONSTRAINT "retry_policies_key_nonempty" CHECK (("btrim"("policy_key") <> ''::"text")),
    CONSTRAINT "retry_policies_multiplier_check" CHECK ((("backoff_multiplier" >= (1)::numeric) AND ("backoff_multiplier" <= (10)::numeric))),
    CONSTRAINT "retry_policies_owner_nonempty" CHECK (("btrim"("owning_application") <> ''::"text")),
    CONSTRAINT "retry_policies_workload_nonempty" CHECK (("btrim"("workload_type") <> ''::"text"))
);


ALTER TABLE "public"."retry_policies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permission_grants" (
    "role_key" "text" NOT NULL,
    "permission_key" "text" NOT NULL,
    "effect" "text" DEFAULT 'allow'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "role_permission_grants_effect_check" CHECK (("effect" = ANY (ARRAY['allow'::"text", 'deny'::"text"])))
);


ALTER TABLE "public"."role_permission_grants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permission_map" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_id" "uuid",
    "permission_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."role_permission_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_key" "text" NOT NULL,
    "role_name" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


COMMENT ON TABLE "public"."roles" IS 'Legacy-compatible global role authority represented in the Core migration chain for deterministic replay.';



CREATE TABLE IF NOT EXISTS "public"."sales_order_draft_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "from_status" "text",
    "to_status" "text",
    "actor_id" "uuid",
    "actor_name" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales_order_draft_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_order_draft_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "line_index" integer NOT NULL,
    "product_id" "uuid",
    "product_name" "text" DEFAULT ''::"text" NOT NULL,
    "sku" "text",
    "raw_quantity" numeric DEFAULT 0 NOT NULL,
    "raw_unit" "text",
    "normalized_quantity" numeric,
    "normalized_unit" "text",
    "operator_quantity" numeric,
    "original_text_span" "text",
    "conversion_explanation" "text",
    "product_confidence" numeric,
    "quantity_confidence" numeric,
    "ai_line_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "operator_line_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales_order_draft_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_order_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "packet_id" "uuid" NOT NULL,
    "extraction_request_key" "text" NOT NULL,
    "status" "text" DEFAULT 'AI_DRAFT'::"text" NOT NULL,
    "client_owner_id" "uuid",
    "client_owner_name" "text",
    "order_creator_id" "uuid",
    "order_creator_name" "text",
    "order_handler_id" "uuid",
    "order_handler_name" "text",
    "approver_id" "uuid",
    "approver_name" "text",
    "company_id" "uuid",
    "company_name" "text",
    "readiness_overall_score" integer DEFAULT 0 NOT NULL,
    "readiness_dimensions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "original_whatsapp_text" "text" DEFAULT ''::"text" NOT NULL,
    "ai_draft_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "operator_final_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "review_notes" "text",
    "rejection_reason" "text",
    "promoted_order_id" "uuid",
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sales_order_drafts_status_check" CHECK (("status" = ANY (ARRAY['AI_DRAFT'::"text", 'UNDER_REVIEW'::"text", 'APPROVED_FOR_SO'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "public"."sales_order_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shadow_clients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sender_phone" "text" NOT NULL,
    "sender_name" "text",
    "extracted_business_name" "text",
    "extracted_gst" "text",
    "extracted_address" "text",
    "extracted_contact_email" "text",
    "status" "text" DEFAULT 'awaiting_details'::"text" NOT NULL,
    "promoted_to_company_id" "uuid",
    "notes" "text",
    "last_prompt_sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."shadow_clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sku_code_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code_type" "text" NOT NULL,
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sku_code_rules_code_type_check" CHECK (("code_type" = ANY (ARRAY['division'::"text", 'category'::"text", 'subcategory'::"text", 'packaging'::"text"])))
);


ALTER TABLE "public"."sku_code_rules" OWNER TO "postgres";


COMMENT ON TABLE "public"."sku_code_rules" IS 'Active code segments for OAS-{division}-{category}-{subcategory}-{packaging}-{serial} SKU builder.';



CREATE TABLE IF NOT EXISTS "public"."starter_packs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "tier" "text" NOT NULL,
    "description" "text",
    "estimated_investment" numeric DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."starter_packs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_consumption_lineage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "reservation_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "sku" "text" NOT NULL,
    "location_code" "text" NOT NULL,
    "consumed_qty" numeric NOT NULL,
    "movement_id" "uuid",
    "lineage_type" "text" NOT NULL,
    "scan_reference" "text",
    "gate_reference" "text",
    "dispatch_lineage_id" "uuid",
    "actor_id" "uuid",
    "actor_role" "text",
    "reason_code" "text",
    "correlation_id" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "stock_consumption_lineage_consumed_qty_check" CHECK (("consumed_qty" > (0)::numeric)),
    CONSTRAINT "stock_consumption_lineage_type_check" CHECK (("lineage_type" = ANY (ARRAY['consumption_finalized'::"text", 'consumption_reversed'::"text", 'variance_recorded'::"text", 'quarantine_applied'::"text", 'quarantine_released'::"text"])))
);


ALTER TABLE "public"."stock_consumption_lineage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "item_id" "uuid",
    "quantity_added" numeric(10,2) NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."stock_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."storage_bucket_contracts" (
    "bucket_id" "text" NOT NULL,
    "classification" "text" NOT NULL,
    "owning_application" "text" NOT NULL,
    "public_delivery" boolean DEFAULT false NOT NULL,
    "write_authority" "text" NOT NULL,
    "path_convention" "text" NOT NULL,
    "retention_notes" "text",
    "migration_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "storage_bucket_contracts_classification_check" CHECK (("classification" = ANY (ARRAY['public_product_media'::"text", 'private_financial'::"text", 'private_customer_document'::"text", 'private_internal'::"text", 'legacy_review'::"text"]))),
    CONSTRAINT "storage_bucket_contracts_migration_status_check" CHECK (("migration_status" = ANY (ARRAY['active'::"text", 'legacy'::"text", 'retire_pending'::"text"])))
);


ALTER TABLE "public"."storage_bucket_contracts" OWNER TO "postgres";


COMMENT ON TABLE "public"."storage_bucket_contracts" IS 'Point 22 authority register for bucket classification, ownership, public-delivery intent, write authority and path conventions.';



CREATE TABLE IF NOT EXISTS "public"."store_requisition_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "requisition_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "requested_qty" integer NOT NULL,
    "fulfilled_qty" integer DEFAULT 0
);


ALTER TABLE "public"."store_requisition_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."store_requisitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "target_store" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "fulfilled_at" timestamp with time zone,
    "is_panic_order" boolean DEFAULT false,
    CONSTRAINT "store_requisitions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'fulfilled'::"text"]))),
    CONSTRAINT "store_requisitions_target_store_check" CHECK (("target_store" = ANY (ARRAY['ready_goods'::"text", 'packing_assembly'::"text", '3rd_party'::"text"])))
);


ALTER TABLE "public"."store_requisitions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suggested_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sender_phone" "text" NOT NULL,
    "sender_name" "text",
    "matched_company_id" "uuid",
    "shadow_client_id" "uuid",
    "extracted_business_name" "text",
    "extracted_items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "extracted_delivery_date" "date",
    "extracted_notes" "text",
    "source_image_url" "text",
    "source_text" "text",
    "source_message_ids" "uuid"[] DEFAULT '{}'::"uuid"[],
    "ai_confidence" numeric DEFAULT 0,
    "ai_model" "text",
    "status" "text" DEFAULT 'pending_review'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "promoted_order_id" "uuid",
    "rejection_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."suggested_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "text" NOT NULL,
    "user_id" "uuid",
    "issue_type" "text" NOT NULL,
    "description" "text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "resolution_notes" "text",
    "product_sku" "text",
    "qty_affected" integer,
    "proof_url" "text",
    "dispatch_date" "date",
    "window_status" "text" DEFAULT 'WITHIN_WINDOW'::"text",
    "routed_to_department" "text",
    "assigned_employee_id" "uuid",
    "sla_first_response_at" timestamp with time zone,
    "sla_action_at" timestamp with time zone,
    "sla_resolved_at" timestamp with time zone,
    "sla_first_response_due" timestamp with time zone,
    "sla_action_due" timestamp with time zone,
    "sla_resolution_due" timestamp with time zone,
    "sla_state" "text" DEFAULT 'pending'::"text",
    "severity" "text" DEFAULT 'Medium'::"text",
    "estimated_financial_loss" numeric DEFAULT 0,
    "customer_rating" integer,
    "admin_rating_speed" integer,
    "admin_rating_quality" integer,
    "admin_rating_communication" integer,
    "rejection_reason_template" "text",
    "resolution_template_used" "text",
    "ai_rewritten_reply" "text",
    "escalated_to_hod" boolean DEFAULT false,
    "commission_blocked" boolean DEFAULT false,
    "company_id" "uuid" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."support_tickets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message" "text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text",
    "expires_at" timestamp with time zone,
    "target_role" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."system_alerts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_settings" (
    "id" integer NOT NULL,
    "global_buffer_days" integer DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."system_settings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."system_settings_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."system_settings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."system_settings_id_seq" OWNED BY "public"."system_settings"."id";



CREATE TABLE IF NOT EXISTS "public"."tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "company_id" "uuid",
    "issue_type" "text",
    "description" "text",
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tickets" OWNER TO "postgres";


COMMENT ON TABLE "public"."tickets" IS 'Deprecated duplicate support-ticket table. Frozen 2026-07-22; public.support_tickets is canonical pending a future physical retirement tranche.';



CREATE TABLE IF NOT EXISTS "public"."user_favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "product_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."user_favorites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_role_map" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "role_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"())
);


ALTER TABLE "public"."user_role_map" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_role_map" IS 'Legacy-compatible authenticated-user to global-role mapping represented for deterministic replay.';



CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "name" "text",
    "email" "text",
    "phone" "text",
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "full_name" "text",
    "mobile_number" "text",
    "department" "text",
    "designation" "text",
    "is_active" boolean DEFAULT true,
    "joined_at" timestamp with time zone,
    "preferred_language" "text" DEFAULT 'en'::"text",
    "invite_status" "text" DEFAULT 'active'::"text",
    "commission_rate_percentage" numeric DEFAULT 2.0,
    "has_seen_tutorial" boolean DEFAULT false,
    "is_sales_executive" boolean DEFAULT false NOT NULL,
    "secondary_phones" "text"[] DEFAULT ARRAY[]::"text"[],
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_batch_summary" AS
 SELECT "id" AS "batch_id",
    "source_filename",
    "status" AS "batch_status",
    "loaded_at",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_raw" "r"
          WHERE ("r"."batch_id" = "b"."id")) AS "raw_rows",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_company_candidates" "c"
          WHERE ("c"."batch_id" = "b"."id")) AS "company_candidates",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_contact_candidates" "ct"
          WHERE ("ct"."batch_id" = "b"."id")) AS "contact_candidates",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_duplicate_review" "d"
          WHERE ("d"."batch_id" = "b"."id")) AS "duplicate_review_rows",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_company_candidates" "c"
          WHERE (("c"."batch_id" = "b"."id") AND ("c"."validation_status" = 'valid'::"text"))) AS "company_valid",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_company_candidates" "c"
          WHERE (("c"."batch_id" = "b"."id") AND ("c"."validation_status" = ANY (ARRAY['error'::"text", 'missing_required'::"text"])))) AS "company_errors",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_contact_candidates" "ct"
          WHERE (("ct"."batch_id" = "b"."id") AND ("ct"."validation_status" = 'valid'::"text"))) AS "contact_valid",
    ( SELECT "count"(*) AS "count"
           FROM "public"."customer_import_duplicate_review" "d"
          WHERE (("d"."batch_id" = "b"."id") AND ("d"."resolution_status" = 'pending'::"text"))) AS "duplicates_pending"
   FROM "public"."customer_import_batches" "b";


ALTER VIEW "public"."v_customer_import_batch_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_company_phone_slots" AS
 SELECT DISTINCT "c"."batch_id",
    "c"."source_customer_key",
    "c"."business_name",
    "phones"."phone_last10",
    "phones"."phone_slot"
   FROM ("public"."customer_import_company_candidates" "c"
     CROSS JOIN LATERAL ( SELECT "c"."phone_last10",
            'primary'::"text" AS "phone_slot"
          WHERE ("c"."phone_last10" IS NOT NULL)
        UNION ALL
         SELECT "c"."phone_secondary_last10" AS "phone_last10",
            'secondary'::"text" AS "phone_slot"
          WHERE (("c"."phone_secondary_last10" IS NOT NULL) AND ("c"."phone_secondary_last10" IS DISTINCT FROM "c"."phone_last10"))) "phones")
  WHERE ("c"."import_action" <> 'skip'::"text");


ALTER VIEW "public"."v_customer_import_company_phone_slots" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_company_required_gaps" AS
 SELECT "id",
    "batch_id",
    "source_customer_key",
    "business_name",
    "validation_status",
    "array_remove"(ARRAY[
        CASE
            WHEN (NULLIF(TRIM(BOTH FROM "business_name"), ''::"text") IS NULL) THEN 'missing_business_name'::"text"
            ELSE NULL::"text"
        END,
        CASE
            WHEN (NULLIF(TRIM(BOTH FROM "source_customer_key"), ''::"text") IS NULL) THEN 'missing_source_customer_key'::"text"
            ELSE NULL::"text"
        END,
        CASE
            WHEN (("payment_terms_normalized" IS NULL) AND (NULLIF(TRIM(BOTH FROM "payment_terms_raw"), ''::"text") IS NOT NULL)) THEN 'invalid_payment_terms'::"text"
            ELSE NULL::"text"
        END,
        CASE
            WHEN ((NULLIF(TRIM(BOTH FROM "gst_number_raw"), ''::"text") IS NOT NULL) AND (("public"."customer_import_normalize_gst"("gst_number_raw") IS NULL) OR ("length"("public"."customer_import_normalize_gst"("gst_number_raw")) <> 15))) THEN 'invalid_gst_format'::"text"
            ELSE NULL::"text"
        END,
        CASE
            WHEN ((NULLIF(TRIM(BOTH FROM "phone_raw"), ''::"text") IS NOT NULL) AND ("public"."customer_import_normalize_phone_last10"("phone_raw") IS NULL)) THEN 'invalid_phone_format'::"text"
            ELSE NULL::"text"
        END], NULL::"text") AS "gap_codes"
   FROM "public"."customer_import_company_candidates" "c"
  WHERE ("import_action" <> 'skip'::"text");


ALTER VIEW "public"."v_customer_import_company_required_gaps" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_contact_phone_gaps" AS
 SELECT "id",
    "batch_id",
    "source_contact_key",
    "source_customer_key",
    "whatsapp_phone_raw",
    "phone_last10",
    "validation_status",
    "array_remove"(ARRAY[
        CASE
            WHEN (NULLIF(TRIM(BOTH FROM "whatsapp_phone_raw"), ''::"text") IS NULL) THEN 'missing_phone'::"text"
            ELSE NULL::"text"
        END,
        CASE
            WHEN ((NULLIF(TRIM(BOTH FROM "whatsapp_phone_raw"), ''::"text") IS NOT NULL) AND ("public"."customer_import_normalize_phone_last10"("whatsapp_phone_raw") IS NULL)) THEN 'invalid_phone_format'::"text"
            ELSE NULL::"text"
        END], NULL::"text") AS "gap_codes"
   FROM "public"."customer_import_contact_candidates" "ct"
  WHERE ("import_action" <> 'skip'::"text");


ALTER VIEW "public"."v_customer_import_contact_phone_gaps" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_duplicate_contact_phone_in_batch" AS
 SELECT "batch_id",
    "phone_last10",
    "count"(*) AS "contact_count",
    "array_agg"("source_contact_key" ORDER BY "source_contact_key") AS "source_contact_keys",
    "array_agg"("source_customer_key" ORDER BY "source_contact_key") AS "source_customer_keys"
   FROM "public"."customer_import_contact_candidates" "ct"
  WHERE (("phone_last10" IS NOT NULL) AND ("import_action" <> 'skip'::"text"))
  GROUP BY "batch_id", "phone_last10"
 HAVING ("count"(*) > 1);


ALTER VIEW "public"."v_customer_import_duplicate_contact_phone_in_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_duplicate_gst_in_batch" AS
 SELECT "batch_id",
    "gst_number_normalized",
    "count"(*) AS "candidate_count",
    "array_agg"("source_customer_key" ORDER BY "source_customer_key") AS "source_customer_keys",
    "array_agg"("business_name" ORDER BY "source_customer_key") AS "business_names"
   FROM "public"."customer_import_company_candidates" "c"
  WHERE (("gst_number_normalized" IS NOT NULL) AND ("import_action" <> 'skip'::"text"))
  GROUP BY "batch_id", "gst_number_normalized"
 HAVING ("count"(*) > 1);


ALTER VIEW "public"."v_customer_import_duplicate_gst_in_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_duplicate_name_in_batch" AS
 SELECT "batch_id",
    "lower"(TRIM(BOTH FROM "business_name")) AS "business_name_normalized",
    "count"(*) AS "candidate_count",
    "array_agg"("source_customer_key" ORDER BY "source_customer_key") AS "source_customer_keys",
    "array_agg"("business_name" ORDER BY "source_customer_key") AS "business_names"
   FROM "public"."customer_import_company_candidates" "c"
  WHERE ((NULLIF(TRIM(BOTH FROM "business_name"), ''::"text") IS NOT NULL) AND ("import_action" <> 'skip'::"text"))
  GROUP BY "batch_id", ("lower"(TRIM(BOTH FROM "business_name")))
 HAVING ("count"(*) > 1);


ALTER VIEW "public"."v_customer_import_duplicate_name_in_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_duplicate_phone_any_in_batch" AS
 SELECT "batch_id",
    "phone_last10",
    "count"(*) AS "occurrence_count",
    "count"(*) FILTER (WHERE ("source_kind" ~~ 'company%'::"text")) AS "company_candidate_count",
    "count"(*) FILTER (WHERE ("source_kind" = 'contact'::"text")) AS "contact_candidate_count",
    "array_agg"("source_key" ORDER BY "source_kind", "source_key") AS "source_keys"
   FROM ( SELECT "slots"."batch_id",
            "slots"."phone_last10",
            ('company_'::"text" || "slots"."phone_slot") AS "source_kind",
            "slots"."source_customer_key" AS "source_key"
           FROM "public"."v_customer_import_company_phone_slots" "slots"
        UNION ALL
         SELECT "ct"."batch_id",
            "ct"."phone_last10",
            'contact'::"text" AS "source_kind",
            "ct"."source_contact_key" AS "source_key"
           FROM "public"."customer_import_contact_candidates" "ct"
          WHERE (("ct"."phone_last10" IS NOT NULL) AND ("ct"."import_action" <> 'skip'::"text"))) "phones"
  GROUP BY "batch_id", "phone_last10"
 HAVING ("count"(*) > 1);


ALTER VIEW "public"."v_customer_import_duplicate_phone_any_in_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_duplicate_phone_in_batch" AS
 SELECT "batch_id",
    "phone_last10",
    "count"(*) AS "candidate_count",
    "array_agg"("source_customer_key" ORDER BY "source_customer_key", "phone_slot") AS "source_customer_keys",
    "array_agg"("business_name" ORDER BY "source_customer_key", "phone_slot") AS "business_names"
   FROM "public"."v_customer_import_company_phone_slots" "slots"
  GROUP BY "batch_id", "phone_last10"
 HAVING ("count"(*) > 1);


ALTER VIEW "public"."v_customer_import_duplicate_phone_in_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_gst_match_existing" AS
 SELECT "c"."batch_id",
    "c"."id" AS "company_candidate_id",
    "c"."source_customer_key",
    "c"."business_name" AS "import_business_name",
    "c"."gst_number_normalized",
    "co"."id" AS "existing_company_id",
    "co"."business_name" AS "existing_business_name",
    "co"."status" AS "existing_status",
        CASE
            WHEN ("co"."id" IS NULL) THEN 'no_match'::"text"
            WHEN (("c"."matched_company_id" IS NOT NULL) AND ("c"."matched_company_id" = "co"."id")) THEN 'already_linked'::"text"
            ELSE 'conflict_existing_gst'::"text"
        END AS "match_outcome"
   FROM ("public"."customer_import_company_candidates" "c"
     LEFT JOIN "public"."companies" "co" ON (("public"."customer_import_normalize_gst"("co"."gst_number") = "c"."gst_number_normalized")))
  WHERE (("c"."gst_number_normalized" IS NOT NULL) AND ("c"."import_action" <> 'skip'::"text"));


ALTER VIEW "public"."v_customer_import_gst_match_existing" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_orphan_contacts" AS
 SELECT "ct"."id",
    "ct"."batch_id",
    "ct"."source_contact_key",
    "ct"."source_customer_key",
    "ct"."company_name",
    "ct"."whatsapp_phone_raw",
    "ct"."validation_status"
   FROM ("public"."customer_import_contact_candidates" "ct"
     LEFT JOIN "public"."customer_import_company_candidates" "c" ON ((("c"."batch_id" = "ct"."batch_id") AND ((("ct"."company_candidate_id" IS NOT NULL) AND ("c"."id" = "ct"."company_candidate_id") AND ("c"."import_action" <> 'skip'::"text")) OR (("ct"."company_candidate_id" IS NULL) AND ("c"."import_action" <> 'skip'::"text") AND (("c"."source_customer_key" = "ct"."source_customer_key") OR ("lower"(TRIM(BOTH FROM "c"."business_name")) = "lower"(TRIM(BOTH FROM "ct"."company_name")))))))))
  WHERE (("ct"."import_action" <> 'skip'::"text") AND ("c"."id" IS NULL));


ALTER VIEW "public"."v_customer_import_orphan_contacts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_customer_import_promotion_readiness" AS
 SELECT "id" AS "batch_id",
    "status" AS "batch_status",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_gst_in_batch" "g"
          WHERE ("g"."batch_id" = "b"."id"))) AS "has_unresolved_duplicate_gst_in_batch",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_phone_any_in_batch" "p"
          WHERE ("p"."batch_id" = "b"."id"))) AS "has_unresolved_duplicate_phone_in_batch",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_contact_phone_in_batch" "cp"
          WHERE ("cp"."batch_id" = "b"."id"))) AS "has_unresolved_duplicate_contact_phone_in_batch",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_name_in_batch" "n"
          WHERE ("n"."batch_id" = "b"."id"))) AS "has_unresolved_duplicate_name_in_batch",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_orphan_contacts" "o"
          WHERE ("o"."batch_id" = "b"."id"))) AS "has_orphan_contacts",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_company_required_gaps" "g"
          WHERE (("g"."batch_id" = "b"."id") AND ("cardinality"("g"."gap_codes") > 0)))) AS "has_required_field_gaps",
    (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_contact_phone_gaps" "g"
          WHERE (("g"."batch_id" = "b"."id") AND ("cardinality"("g"."gap_codes") > 0)))) AS "has_contact_phone_gaps",
    (EXISTS ( SELECT 1
           FROM "public"."customer_import_duplicate_review" "d"
          WHERE (("d"."batch_id" = "b"."id") AND ("d"."resolution_status" = 'pending'::"text")))) AS "has_pending_duplicate_review",
    (EXISTS ( SELECT 1
           FROM "public"."customer_import_company_candidates" "c"
          WHERE (("c"."batch_id" = "b"."id") AND ("c"."import_action" = 'review'::"text")))) AS "has_company_rows_pending_review",
    (EXISTS ( SELECT 1
           FROM "public"."customer_import_contact_candidates" "ct"
          WHERE (("ct"."batch_id" = "b"."id") AND ("ct"."import_action" = 'review'::"text")))) AS "has_contact_rows_pending_review",
    ((NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_gst_in_batch" "g"
          WHERE ("g"."batch_id" = "b"."id")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_phone_any_in_batch" "p"
          WHERE ("p"."batch_id" = "b"."id")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_duplicate_name_in_batch" "n"
          WHERE ("n"."batch_id" = "b"."id")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_orphan_contacts" "o"
          WHERE ("o"."batch_id" = "b"."id")))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_company_required_gaps" "g"
          WHERE (("g"."batch_id" = "b"."id") AND ("cardinality"("g"."gap_codes") > 0))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."v_customer_import_contact_phone_gaps" "g"
          WHERE (("g"."batch_id" = "b"."id") AND ("cardinality"("g"."gap_codes") > 0))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."customer_import_duplicate_review" "d"
          WHERE (("d"."batch_id" = "b"."id") AND ("d"."resolution_status" = 'pending'::"text"))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."customer_import_company_candidates" "c"
          WHERE (("c"."batch_id" = "b"."id") AND ("c"."import_action" = 'review'::"text"))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."customer_import_contact_candidates" "ct"
          WHERE (("ct"."batch_id" = "b"."id") AND ("ct"."import_action" = 'review'::"text")))))) AS "safe_for_staging_promotion_review"
   FROM "public"."customer_import_batches" "b";


ALTER VIEW "public"."v_customer_import_promotion_readiness" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "type" "text",
    "amount" numeric DEFAULT 0 NOT NULL,
    "reference" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "wallet_transactions_type_check" CHECK (("type" = ANY (ARRAY['credit'::"text", 'debit'::"text", 'withdrawal'::"text"])))
);


ALTER TABLE "public"."wallet_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_automations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "trigger_type" character varying(50) NOT NULL,
    "message_template" character varying(255),
    "provider" character varying(50) NOT NULL,
    "provider_message_id" character varying(100),
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "retry_count" integer DEFAULT 0,
    "failure_reason" "text",
    "sent_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."whatsapp_automations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_buffer" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sender_phone" "text" NOT NULL,
    "sender_name" "text",
    "message_type" "text" DEFAULT 'text'::"text",
    "text_content" "text",
    "media_url" "text",
    "media_mime_type" "text",
    "raw_payload" "jsonb",
    "webhook_id" "uuid",
    "bundle_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "flushed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."whatsapp_buffer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "api_key" "text" NOT NULL,
    "instance_id" "text" NOT NULL,
    "webhook_secret" "text",
    "default_country_code" "text" DEFAULT '+91'::"text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."whatsapp_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "phone_number" character varying(20) NOT NULL,
    "customer_name" character varying(255),
    "company_name" character varying(255),
    "wa_contact_id" character varying(100),
    "first_message_at" timestamp without time zone,
    "last_message_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."whatsapp_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."whatsapp_message_packets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "stitched_content" "jsonb" NOT NULL,
    "fragment_count" integer DEFAULT 0 NOT NULL,
    "first_message_at" timestamp without time zone NOT NULL,
    "last_message_at" timestamp without time zone NOT NULL,
    "status" character varying(20) DEFAULT 'open'::character varying NOT NULL,
    "closed_at" timestamp without time zone,
    "manual_split" boolean DEFAULT false,
    "manual_split_reason" "text",
    "manual_split_by" "uuid",
    "manual_split_at" timestamp without time zone,
    "manual_merge_parent_id" "uuid",
    "manual_merge_reason" "text",
    "manual_merge_by" "uuid",
    "manual_merge_at" timestamp without time zone,
    "sender_identified" boolean DEFAULT false,
    "intent_classified" boolean DEFAULT false,
    "routed_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "whatsapp_message_packets_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['open'::character varying, 'closed'::character varying])::"text"[])))
);


ALTER TABLE "public"."whatsapp_message_packets" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_message_packets" IS 'Processing aid for grouping related WhatsApp messages from same contact within stitching window. Source of truth remains whatsapp_messages. Packets support manual split/merge by operators.';



COMMENT ON COLUMN "public"."whatsapp_message_packets"."stitched_content" IS 'JSONB metadata about the packet: summary, extracted intent hints, timestamps. Used for quick packet identification without fetching all messages.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "direction" character varying(10) NOT NULL,
    "message_type" character varying(50) DEFAULT 'text'::character varying NOT NULL,
    "content" "text",
    "media_url" "text",
    "provider" character varying(50) NOT NULL,
    "provider_message_id" character varying(100),
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "retry_count" integer DEFAULT 0,
    "failure_reason" "text",
    "message_timestamp" timestamp without time zone DEFAULT "now"(),
    "created_at" timestamp without time zone DEFAULT "now"(),
    "packet_id" "uuid",
    "packet_sequence" integer,
    "packet_status" character varying(20) DEFAULT 'open'::character varying,
    "is_raw" boolean DEFAULT true,
    "stitched_at" timestamp without time zone,
    CONSTRAINT "whatsapp_messages_direction_check" CHECK ((("direction")::"text" = ANY ((ARRAY['inbound'::character varying, 'outbound'::character varying])::"text"[]))),
    CONSTRAINT "whatsapp_messages_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'sent'::character varying, 'delivered'::character varying, 'read'::character varying, 'failed'::character varying, 'received'::character varying])::"text"[])))
);


ALTER TABLE "public"."whatsapp_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."whatsapp_messages"."packet_id" IS 'Foreign key to whatsapp_message_packets. NULL if message not yet stitched. Set by whatsapp-message-stitcher Edge Function.';



COMMENT ON COLUMN "public"."whatsapp_messages"."is_raw" IS 'true = direct from webhook (unstitched), false = already processed through stitcher.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_override_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "packet_id" "uuid" NOT NULL,
    "operator_id" "uuid" NOT NULL,
    "operator_name" character varying NOT NULL,
    "previous_team" character varying,
    "new_team" character varying NOT NULL,
    "assigned_to_user_id" "uuid",
    "priority" character varying NOT NULL,
    "reason" "text" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "whatsapp_override_log_priority_check" CHECK (("lower"(("priority")::"text") = ANY (ARRAY['high'::"text", 'normal'::"text", 'low'::"text"])))
);


ALTER TABLE "public"."whatsapp_override_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_override_log" IS 'C2A audit: manual packet/team overrides. RLS: SELECT (operations/finance/director), INSERT (operations/director). No UPDATE/DELETE policies on this table.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_stitched_packets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "message_count" integer DEFAULT 0,
    "message_ids" "jsonb",
    "packet_sequence" integer,
    "stitching_window_seconds" integer DEFAULT 300,
    "first_message_at" timestamp without time zone NOT NULL,
    "last_message_at" timestamp without time zone NOT NULL,
    "status" character varying(20) DEFAULT 'open'::character varying NOT NULL,
    "closed_at" timestamp without time zone,
    "manual_split" boolean DEFAULT false,
    "manual_split_reason" "text",
    "manual_split_by" "uuid",
    "manual_split_at" timestamp without time zone,
    "manual_merge_parent_id" "uuid",
    "manual_merge_reason" "text",
    "manual_merge_by" "uuid",
    "manual_merge_at" timestamp without time zone,
    "sender_identified" boolean DEFAULT false,
    "intent_classified" boolean DEFAULT false,
    "routed_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "whatsapp_stitched_packets_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['open'::character varying, 'closed'::character varying])::"text"[])))
);


ALTER TABLE "public"."whatsapp_stitched_packets" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_stitched_packets" IS 'Processing aid for grouping related WhatsApp messages from same contact within stitching window. Source of truth remains whatsapp_messages.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_studio_inbox_bridge_state" (
    "id" smallint DEFAULT 1 NOT NULL,
    "last_erp_cursor" timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone NOT NULL,
    "last_erp_row_id" "text",
    "last_run_at" timestamp with time zone,
    "last_run_rows_read" integer DEFAULT 0 NOT NULL,
    "last_run_rows_ingested" integer DEFAULT 0 NOT NULL,
    "last_run_rows_duplicate" integer DEFAULT 0 NOT NULL,
    "last_run_rows_skipped" integer DEFAULT 0 NOT NULL,
    "last_run_rows_failed" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "last_run_errors" "jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "whatsapp_studio_inbox_bridge_state_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."whatsapp_studio_inbox_bridge_state" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_studio_inbox_bridge_state" IS 'Phase 2G ERP→Studio inbox bridge cursor. Service role only; no operator UI.';



CREATE TABLE IF NOT EXISTS "public"."whatsapp_suggestions_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "packet_id" "uuid" NOT NULL,
    "suggestion_type" character varying NOT NULL,
    "description" "text" NOT NULL,
    "action" "text" NOT NULL,
    "confidence" numeric(3,2) NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."whatsapp_suggestions_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."whatsapp_suggestions_log" IS 'C2A audit: optional persisted suggestions. RLS: SELECT (operations/finance/director) only for authenticated; no INSERT/UPDATE/DELETE policies for authenticated.';



ALTER TABLE ONLY "public"."system_settings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."system_settings_id_seq"'::"regclass");



ALTER TABLE ONLY "cleanup_archive"."auth_user_snapshot_20260722"
    ADD CONSTRAINT "auth_user_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."catalogue_approval_audit_snapshot_20260722"
    ADD CONSTRAINT "catalogue_approval_audit_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."catalogue_product_draft_snapshot_20260722"
    ADD CONSTRAINT "catalogue_product_draft_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."catalogue_version_snapshot_20260722"
    ADD CONSTRAINT "catalogue_version_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."catalogue_version_snapshot_20260722"
    ADD CONSTRAINT "catalogue_version_snapshot_202607_product_id_version_number_key" UNIQUE ("product_id", "version_number");



ALTER TABLE ONLY "cleanup_archive"."deleted_order_manifest_20260722"
    ADD CONSTRAINT "deleted_order_manifest_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."deleted_product_manifest_20260722"
    ADD CONSTRAINT "deleted_product_manifest_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."deleted_user_manifest_20260722"
    ADD CONSTRAINT "deleted_user_manifest_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_ai_drafts_snapshot_20260722"
    ADD CONSTRAINT "final_ai_drafts_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_catalogue_versions_snapshot_20260722"
    ADD CONSTRAINT "final_catalogue_versions_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_catalogue_versions_snapshot_20260722"
    ADD CONSTRAINT "final_catalogue_versions_snapshot_product_id_version_number_key" UNIQUE ("product_id", "version_number");



ALTER TABLE ONLY "cleanup_archive"."final_order_items_snapshot_20260722"
    ADD CONSTRAINT "final_order_items_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_order_snapshot_20260722"
    ADD CONSTRAINT "final_order_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_order_snapshot_20260722"
    ADD CONSTRAINT "final_order_snapshot_20260722_tracking_token_key" UNIQUE ("tracking_token");



ALTER TABLE ONLY "cleanup_archive"."final_product_aliases_snapshot_20260722"
    ADD CONSTRAINT "final_product_aliases_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_product_bom_snapshot_20260722"
    ADD CONSTRAINT "final_product_bom_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_product_media_snapshot_20260722"
    ADD CONSTRAINT "final_product_media_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_product_moq_snapshot_20260722"
    ADD CONSTRAINT "final_product_moq_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_product_pricing_snapshot_20260722"
    ADD CONSTRAINT "final_product_pricing_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_product_snapshot_20260722"
    ADD CONSTRAINT "final_product_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722"
    ADD CONSTRAINT "final_whatsapp_drafts_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722"
    ADD CONSTRAINT "final_whatsapp_drafts_snapshot_20260722_source_message_id_key" UNIQUE ("source_message_id");



ALTER TABLE ONLY "cleanup_archive"."final_whatsapp_operator_decisions_snapshot_20260722"
    ADD CONSTRAINT "final_whatsapp_operator_decisions_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."order_delete_manifest_20260722"
    ADD CONSTRAINT "order_delete_manifest_20260722_pkey" PRIMARY KEY ("order_id");



ALTER TABLE ONLY "cleanup_archive"."order_snapshot_20260722"
    ADD CONSTRAINT "order_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."order_snapshot_20260722"
    ADD CONSTRAINT "order_snapshot_20260722_tracking_token_key" UNIQUE ("tracking_token");



ALTER TABLE ONLY "cleanup_archive"."product_alias_snapshot_20260722"
    ADD CONSTRAINT "product_alias_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."product_moq_rule_snapshot_20260722"
    ADD CONSTRAINT "product_moq_rule_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."product_pricing_rule_snapshot_20260722"
    ADD CONSTRAINT "product_pricing_rule_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."product_snapshot_20260722"
    ADD CONSTRAINT "product_snapshot_20260722_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "cleanup_archive"."support_only_product_delete_manifest_20260722"
    ADD CONSTRAINT "support_only_product_delete_manifest_20260722_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "cleanup_archive"."user_delete_manifest_20260722"
    ADD CONSTRAINT "user_delete_manifest_20260722_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."access_permissions"
    ADD CONSTRAINT "access_permissions_pkey" PRIMARY KEY ("permission_key");



ALTER TABLE ONLY "public"."admin_manual_entries"
    ADD CONSTRAINT "admin_manual_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_setting_key_key" UNIQUE ("setting_key");



ALTER TABLE ONLY "public"."archive_logs"
    ADD CONSTRAINT "archive_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."auth_logs"
    ADD CONSTRAINT "auth_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."b2b_applications"
    ADD CONSTRAINT "b2b_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bi_monthly_ledgers"
    ADD CONSTRAINT "bi_monthly_ledgers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_ai_studio_draft_audit_log"
    ADD CONSTRAINT "catalogue_ai_studio_draft_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_ai_studio_drafts"
    ADD CONSTRAINT "catalogue_ai_studio_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_alias_drafts"
    ADD CONSTRAINT "catalogue_alias_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_approval_audit"
    ADD CONSTRAINT "catalogue_approval_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_bom_drafts"
    ADD CONSTRAINT "catalogue_bom_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_media_submissions"
    ADD CONSTRAINT "catalogue_media_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_moq_drafts"
    ADD CONSTRAINT "catalogue_moq_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_pricing_drafts"
    ADD CONSTRAINT "catalogue_pricing_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_product_drafts"
    ADD CONSTRAINT "catalogue_product_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_product_mappings"
    ADD CONSTRAINT "catalogue_product_mappings_external_unique" UNIQUE ("source_app", "external_catalogue_product_id");



ALTER TABLE ONLY "public"."catalogue_product_mappings"
    ADD CONSTRAINT "catalogue_product_mappings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_product_mappings"
    ADD CONSTRAINT "catalogue_product_mappings_sku_unique" UNIQUE ("source_app", "sku");



ALTER TABLE ONLY "public"."catalogue_sync_events"
    ADD CONSTRAINT "catalogue_sync_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_tag_drafts"
    ADD CONSTRAINT "catalogue_tag_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_versions"
    ADD CONSTRAINT "catalogue_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."catalogue_versions"
    ADD CONSTRAINT "catalogue_versions_product_id_version_number_key" UNIQUE ("product_id", "version_number");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_interactions"
    ADD CONSTRAINT "client_interactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."commission_payouts"
    ADD CONSTRAINT "commission_payouts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_requests"
    ADD CONSTRAINT "credit_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_rescue_events"
    ADD CONSTRAINT "credit_rescue_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crm_tasks"
    ADD CONSTRAINT "crm_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_import_batches"
    ADD CONSTRAINT "customer_import_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_import_company_candidates"
    ADD CONSTRAINT "customer_import_company_candid_batch_id_source_customer_key_key" UNIQUE ("batch_id", "source_customer_key");



ALTER TABLE ONLY "public"."customer_import_company_candidates"
    ADD CONSTRAINT "customer_import_company_candidates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_import_contact_candidates"
    ADD CONSTRAINT "customer_import_contact_candida_batch_id_source_contact_key_key" UNIQUE ("batch_id", "source_contact_key");



ALTER TABLE ONLY "public"."customer_import_contact_candidates"
    ADD CONSTRAINT "customer_import_contact_candidates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_import_duplicate_review"
    ADD CONSTRAINT "customer_import_duplicate_rev_batch_id_duplicate_type_dupli_key" UNIQUE ("batch_id", "duplicate_type", "duplicate_key_normalized");



ALTER TABLE ONLY "public"."customer_import_duplicate_review"
    ADD CONSTRAINT "customer_import_duplicate_review_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_import_raw"
    ADD CONSTRAINT "customer_import_raw_batch_id_row_hash_key" UNIQUE ("batch_id", "row_hash");



ALTER TABLE ONLY "public"."customer_import_raw"
    ADD CONSTRAINT "customer_import_raw_batch_id_source_tab_source_row_number_key" UNIQUE ("batch_id", "source_tab", "source_row_number");



ALTER TABLE ONLY "public"."customer_import_raw"
    ADD CONSTRAINT "customer_import_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_production_logs"
    ADD CONSTRAINT "daily_production_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dead_letter_entries"
    ADD CONSTRAINT "dead_letter_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."debug_webhooks"
    ADD CONSTRAINT "debug_webhooks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."delivery_addresses"
    ADD CONSTRAINT "delivery_addresses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatch_cartons"
    ADD CONSTRAINT "dispatch_cartons_barcode_string_key" UNIQUE ("barcode_string");



ALTER TABLE ONLY "public"."dispatch_cartons"
    ADD CONSTRAINT "dispatch_cartons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatch_completion_evidence"
    ADD CONSTRAINT "dispatch_completion_evidence_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatch_readiness_evidence"
    ADD CONSTRAINT "dispatch_readiness_evidence_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatch_release_lineage"
    ADD CONSTRAINT "dispatch_release_lineage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatches"
    ADD CONSTRAINT "dispatches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_performance_logs"
    ADD CONSTRAINT "employee_performance_logs_employee_id_period_start_key" UNIQUE ("employee_id", "period_start");



ALTER TABLE ONLY "public"."employee_performance_logs"
    ADD CONSTRAINT "employee_performance_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exchange_rates"
    ADD CONSTRAINT "exchange_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."factory_holidays"
    ADD CONSTRAINT "factory_holidays_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."factory_inventory"
    ADD CONSTRAINT "factory_inventory_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."finance_review_evidence"
    ADD CONSTRAINT "finance_review_evidence_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."freight_ledger"
    ADD CONSTRAINT "freight_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."identity_profiles"
    ADD CONSTRAINT "identity_profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."inventory_adjustments"
    ADD CONSTRAINT "inventory_adjustments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_reservation_allocations"
    ADD CONSTRAINT "inventory_reservation_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_reservations"
    ADD CONSTRAINT "inventory_reservations_number_unique" UNIQUE ("reservation_number");



ALTER TABLE ONLY "public"."inventory_reservations"
    ADD CONSTRAINT "inventory_reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock_balances"
    ADD CONSTRAINT "inventory_stock_balances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock_balances"
    ADD CONSTRAINT "inventory_stock_balances_unique" UNIQUE ("product_id", "sku", "location_code");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inward_material_advice"
    ADD CONSTRAINT "inward_material_advice_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inward_material_items"
    ADD CONSTRAINT "inward_material_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ledger_disputes"
    ADD CONSTRAINT "ledger_disputes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."moq_rules"
    ADD CONSTRAINT "moq_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_events"
    ADD CONSTRAINT "notification_events_event_key_key" UNIQUE ("event_key");



ALTER TABLE ONLY "public"."notification_events"
    ADD CONSTRAINT "notification_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_outbox"
    ADD CONSTRAINT "notification_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_audit_logs"
    ADD CONSTRAINT "ols_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_carton_contents"
    ADD CONSTRAINT "ols_carton_contents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_cartons"
    ADD CONSTRAINT "ols_cartons_carton_no_key" UNIQUE ("carton_no");



ALTER TABLE ONLY "public"."ols_cartons"
    ADD CONSTRAINT "ols_cartons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_departments"
    ADD CONSTRAINT "ols_departments_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."ols_departments"
    ADD CONSTRAINT "ols_departments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_dispatch_document_bundles"
    ADD CONSTRAINT "ols_dispatch_document_bundles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_dpl_cartons"
    ADD CONSTRAINT "ols_dpl_cartons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_dpl_documents"
    ADD CONSTRAINT "ols_dpl_documents_dpl_no_key" UNIQUE ("dpl_no");



ALTER TABLE ONLY "public"."ols_dpl_documents"
    ADD CONSTRAINT "ols_dpl_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_finance_pi_cartons"
    ADD CONSTRAINT "ols_finance_pi_cartons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_finance_pi_lines"
    ADD CONSTRAINT "ols_finance_pi_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_finance_pi"
    ADD CONSTRAINT "ols_finance_pi_pi_no_key" UNIQUE ("pi_no");



ALTER TABLE ONLY "public"."ols_finance_pi"
    ADD CONSTRAINT "ols_finance_pi_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_gate_scans"
    ADD CONSTRAINT "ols_gate_scans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_inventory_movements"
    ADD CONSTRAINT "ols_inventory_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_label_templates"
    ADD CONSTRAINT "ols_label_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_manual_override_logs"
    ADD CONSTRAINT "ols_manual_override_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_orders_cache"
    ADD CONSTRAINT "ols_orders_cache_order_number_key" UNIQUE ("order_number");



ALTER TABLE ONLY "public"."ols_orders_cache"
    ADD CONSTRAINT "ols_orders_cache_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_permissions"
    ADD CONSTRAINT "ols_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_permissions"
    ADD CONSTRAINT "ols_permissions_role_module_key" UNIQUE ("role", "module");



ALTER TABLE ONLY "public"."ols_print_jobs"
    ADD CONSTRAINT "ols_print_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_print_logs"
    ADD CONSTRAINT "ols_print_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_printer_settings"
    ADD CONSTRAINT "ols_printer_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_printers"
    ADD CONSTRAINT "ols_printers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_production_batches"
    ADD CONSTRAINT "ols_production_batches_batch_no_key" UNIQUE ("batch_no");



ALTER TABLE ONLY "public"."ols_production_batches"
    ADD CONSTRAINT "ols_production_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_production_labels"
    ADD CONSTRAINT "ols_production_labels_label_no_key" UNIQUE ("label_no");



ALTER TABLE ONLY "public"."ols_production_labels"
    ADD CONSTRAINT "ols_production_labels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_products_cache"
    ADD CONSTRAINT "ols_products_cache_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_products_cache"
    ADD CONSTRAINT "ols_products_cache_sku_key" UNIQUE ("sku");



ALTER TABLE ONLY "public"."ols_profiles_light"
    ADD CONSTRAINT "ols_profiles_light_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_profiles_light"
    ADD CONSTRAINT "ols_profiles_light_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."ols_reprint_requests"
    ADD CONSTRAINT "ols_reprint_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_scan_history"
    ADD CONSTRAINT "ols_scan_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_settings"
    ADD CONSTRAINT "ols_settings_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."ols_settings"
    ADD CONSTRAINT "ols_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_shipping_labels"
    ADD CONSTRAINT "ols_shipping_labels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_shipping_labels"
    ADD CONSTRAINT "ols_shipping_labels_qr_ref_key" UNIQUE ("qr_ref");



ALTER TABLE ONLY "public"."ols_shipping_labels"
    ADD CONSTRAINT "ols_shipping_labels_shipping_no_key" UNIQUE ("shipping_no");



ALTER TABLE ONLY "public"."ols_stock_units"
    ADD CONSTRAINT "ols_stock_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ols_stock_units"
    ADD CONSTRAINT "ols_stock_units_production_label_id_key" UNIQUE ("production_label_id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operational_queue_assignments"
    ADD CONSTRAINT "operational_queue_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operational_queue_items"
    ADD CONSTRAINT "operational_queue_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operational_scan_records"
    ADD CONSTRAINT "operational_scan_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."operational_search_index"
    ADD CONSTRAINT "operational_search_index_entity_source_unique" UNIQUE ("entity_type", "entity_id", "source");



ALTER TABLE ONLY "public"."operational_search_index"
    ADD CONSTRAINT "operational_search_index_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_attachments"
    ADD CONSTRAINT "order_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_payments"
    ADD CONSTRAINT "order_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_tracking_token_key" UNIQUE ("tracking_token");



ALTER TABLE ONLY "public"."org_branches"
    ADD CONSTRAINT "org_branches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."org_companies"
    ADD CONSTRAINT "org_companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."org_contacts"
    ADD CONSTRAINT "org_contacts_auth_user_id_key" UNIQUE ("auth_user_id");



ALTER TABLE ONLY "public"."org_contacts"
    ADD CONSTRAINT "org_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."org_membership_branch_scopes"
    ADD CONSTRAINT "org_membership_branch_scopes_pkey" PRIMARY KEY ("membership_id", "branch_id");



ALTER TABLE ONLY "public"."org_membership_roles"
    ADD CONSTRAINT "org_membership_roles_pkey" PRIMARY KEY ("membership_id", "role_key");



ALTER TABLE ONLY "public"."org_memberships"
    ADD CONSTRAINT "org_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."packing_lists"
    ADD CONSTRAINT "packing_lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_permission_key_key" UNIQUE ("permission_key");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."portal_access_invites"
    ADD CONSTRAINT "portal_access_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."premium_announcements"
    ADD CONSTRAINT "premium_announcements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pricing_slabs"
    ADD CONSTRAINT "pricing_slabs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pricing_slabs"
    ADD CONSTRAINT "pricing_slabs_slab_name_key" UNIQUE ("slab_name");



ALTER TABLE ONLY "public"."product_aliases"
    ADD CONSTRAINT "product_aliases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_bom"
    ADD CONSTRAINT "product_bom_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_media"
    ADD CONSTRAINT "product_media_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_moq_rules"
    ADD CONSTRAINT "product_moq_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_pricing_rules"
    ADD CONSTRAINT "product_pricing_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_tag_mapping"
    ADD CONSTRAINT "product_tag_mapping_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_tag_mapping"
    ADD CONSTRAINT "product_tag_mapping_product_id_tag_id_key" UNIQUE ("product_id", "tag_id");



ALTER TABLE ONLY "public"."product_tags"
    ADD CONSTRAINT "product_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_tags"
    ADD CONSTRAINT "product_tags_tag_key_key" UNIQUE ("tag_key");



ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_sku_key" UNIQUE ("sku");



ALTER TABLE ONLY "public"."production_issues"
    ADD CONSTRAINT "production_issues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."production_jobs"
    ADD CONSTRAINT "production_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."production_pauses"
    ADD CONSTRAINT "production_pauses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."production_rgs_transfers"
    ADD CONSTRAINT "production_rgs_transfers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_change_requests"
    ADD CONSTRAINT "profile_change_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."realtime_subscription_contracts"
    ADD CONSTRAINT "realtime_subscription_contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."realtime_subscription_contracts"
    ADD CONSTRAINT "realtime_subscription_contracts_schema_name_table_name_key" UNIQUE ("schema_name", "table_name");



ALTER TABLE ONLY "public"."retry_policies"
    ADD CONSTRAINT "retry_policies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."retry_policies"
    ADD CONSTRAINT "retry_policies_policy_key_key" UNIQUE ("policy_key");



ALTER TABLE ONLY "public"."role_permission_grants"
    ADD CONSTRAINT "role_permission_grants_pkey" PRIMARY KEY ("role_key", "permission_key");



ALTER TABLE ONLY "public"."role_permission_map"
    ADD CONSTRAINT "role_permission_map_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permission_map"
    ADD CONSTRAINT "role_permission_map_role_id_permission_id_key" UNIQUE ("role_id", "permission_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_role_key_key" UNIQUE ("role_key");



ALTER TABLE ONLY "public"."sales_order_draft_audit_log"
    ADD CONSTRAINT "sales_order_draft_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_order_draft_lines"
    ADD CONSTRAINT "sales_order_draft_lines_draft_line_unique" UNIQUE ("draft_id", "line_index");



ALTER TABLE ONLY "public"."sales_order_draft_lines"
    ADD CONSTRAINT "sales_order_draft_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_order_drafts"
    ADD CONSTRAINT "sales_order_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shadow_clients"
    ADD CONSTRAINT "shadow_clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sku_code_rules"
    ADD CONSTRAINT "sku_code_rules_code_type_code_key" UNIQUE ("code_type", "code");



ALTER TABLE ONLY "public"."sku_code_rules"
    ADD CONSTRAINT "sku_code_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."starter_packs"
    ADD CONSTRAINT "starter_packs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_consumption_lineage"
    ADD CONSTRAINT "stock_consumption_lineage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_logs"
    ADD CONSTRAINT "stock_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."storage_bucket_contracts"
    ADD CONSTRAINT "storage_bucket_contracts_pkey" PRIMARY KEY ("bucket_id");



ALTER TABLE ONLY "public"."store_requisition_items"
    ADD CONSTRAINT "store_requisition_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."store_requisitions"
    ADD CONSTRAINT "store_requisitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suggested_orders"
    ADD CONSTRAINT "suggested_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_tickets"
    ADD CONSTRAINT "support_tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_alerts"
    ADD CONSTRAINT "system_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_settings"
    ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "unique_mobile_number" UNIQUE ("mobile_number");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "unique_phone" UNIQUE ("mobile_number");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "unique_phone_number" UNIQUE ("mobile_number");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_company_id_product_id_key" UNIQUE ("company_id", "product_id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_role_map"
    ADD CONSTRAINT "user_role_map_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_role_map"
    ADD CONSTRAINT "user_role_map_user_id_role_id_key" UNIQUE ("user_id", "role_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_automations"
    ADD CONSTRAINT "whatsapp_automations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_buffer"
    ADD CONSTRAINT "whatsapp_buffer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_config"
    ADD CONSTRAINT "whatsapp_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_contacts"
    ADD CONSTRAINT "whatsapp_contacts_phone_number_key" UNIQUE ("phone_number");



ALTER TABLE ONLY "public"."whatsapp_contacts"
    ADD CONSTRAINT "whatsapp_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_inbound_messages"
    ADD CONSTRAINT "whatsapp_inbound_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_inbound_messages"
    ADD CONSTRAINT "whatsapp_inbound_messages_provider_message_id_key" UNIQUE ("provider_message_id");



ALTER TABLE ONLY "public"."whatsapp_message_packets"
    ADD CONSTRAINT "whatsapp_message_packets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_messages"
    ADD CONSTRAINT "whatsapp_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_operator_decisions"
    ADD CONSTRAINT "whatsapp_operator_decisions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_override_log"
    ADD CONSTRAINT "whatsapp_override_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_sales_order_drafts"
    ADD CONSTRAINT "whatsapp_sales_order_drafts_one_per_message" UNIQUE ("source_message_id");



ALTER TABLE ONLY "public"."whatsapp_sales_order_drafts"
    ADD CONSTRAINT "whatsapp_sales_order_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_stitched_packets"
    ADD CONSTRAINT "whatsapp_stitched_packets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_studio_inbox_bridge_state"
    ADD CONSTRAINT "whatsapp_studio_inbox_bridge_state_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."whatsapp_suggestions_log"
    ADD CONSTRAINT "whatsapp_suggestions_log_pkey" PRIMARY KEY ("id");



CREATE INDEX "catalogue_approval_audit_snapshot_20260722_created_at_idx" ON "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" USING "btree" ("created_at");



CREATE INDEX "catalogue_approval_audit_snapshot_20260722_draft_id_idx" ON "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" USING "btree" ("draft_id");



CREATE INDEX "catalogue_approval_audit_snapshot_20260722_draft_table_idx" ON "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" USING "btree" ("draft_table");



CREATE INDEX "catalogue_approval_audit_snapshot_20260722_performed_by_idx" ON "cleanup_archive"."catalogue_approval_audit_snapshot_20260722" USING "btree" ("performed_by");



CREATE INDEX "catalogue_product_draft_snapshot_20260722_created_at_idx" ON "cleanup_archive"."catalogue_product_draft_snapshot_20260722" USING "btree" ("created_at");



CREATE INDEX "catalogue_product_draft_snapshot_20260722_payload_idx" ON "cleanup_archive"."catalogue_product_draft_snapshot_20260722" USING "gin" ("payload");



CREATE INDEX "catalogue_product_draft_snapshot_20260722_status_idx" ON "cleanup_archive"."catalogue_product_draft_snapshot_20260722" USING "btree" ("status");



CREATE INDEX "catalogue_product_draft_snapshot_20260722_submitted_by_idx" ON "cleanup_archive"."catalogue_product_draft_snapshot_20260722" USING "btree" ("submitted_by");



CREATE INDEX "catalogue_product_draft_snapshot_20260722_target_record_id_idx" ON "cleanup_archive"."catalogue_product_draft_snapshot_20260722" USING "btree" ("target_record_id");



CREATE INDEX "catalogue_version_snapshot_202607_product_id_version_number_idx" ON "cleanup_archive"."catalogue_version_snapshot_20260722" USING "btree" ("product_id", "version_number" DESC);



CREATE INDEX "final_ai_drafts_snapshot_20260722_created_at_idx" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "final_ai_drafts_snapshot_20260722_product_id_idx" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("product_id") WHERE ("status" = ANY (ARRAY['DRAFT'::"text", 'UNDER_REVIEW'::"text"]));



CREATE INDEX "final_ai_drafts_snapshot_20260722_product_id_version_number_idx" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("product_id", "version_number" DESC);



CREATE INDEX "final_ai_drafts_snapshot_20260722_status_updated_at_idx" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("status", "updated_at" DESC);



CREATE INDEX "final_ai_drafts_snapshot_20260722_updated_at_idx" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("updated_at" DESC);



CREATE UNIQUE INDEX "final_ai_drafts_snapshot_2026072_product_id_version_number_idx1" ON "cleanup_archive"."final_ai_drafts_snapshot_20260722" USING "btree" ("product_id", "version_number");



CREATE INDEX "final_catalogue_versions_snapshot_product_id_version_number_idx" ON "cleanup_archive"."final_catalogue_versions_snapshot_20260722" USING "btree" ("product_id", "version_number" DESC);



CREATE INDEX "final_order_snapshot_20260722_finance_verified_by_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("finance_verified_by");



CREATE INDEX "final_order_snapshot_20260722_is_duplicate_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("is_duplicate") WHERE ("is_duplicate" = true);



CREATE INDEX "final_order_snapshot_20260722_is_waste_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("is_waste") WHERE ("is_waste" = false);



CREATE INDEX "final_order_snapshot_20260722_needs_clarification_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("needs_clarification") WHERE ("needs_clarification" = true);



CREATE UNIQUE INDEX "final_order_snapshot_20260722_order_number_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("order_number");



CREATE INDEX "final_order_snapshot_20260722_payment_status_finance_verifi_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("payment_status", "finance_verified_at" DESC);



CREATE UNIQUE INDEX "final_order_snapshot_20260722_wamid_idx" ON "cleanup_archive"."final_order_snapshot_20260722" USING "btree" ("wamid") WHERE ("wamid" IS NOT NULL);



CREATE INDEX "final_product_aliases_snapshot_20260722_lower_idx" ON "cleanup_archive"."final_product_aliases_snapshot_20260722" USING "btree" ("lower"("alias_text"));



CREATE INDEX "final_product_bom_snapshot_20260722_product_id_bom_type_idx" ON "cleanup_archive"."final_product_bom_snapshot_20260722" USING "btree" ("product_id", "bom_type");



CREATE INDEX "final_product_media_snapshot_20260722_product_id_idx" ON "cleanup_archive"."final_product_media_snapshot_20260722" USING "btree" ("product_id");



CREATE INDEX "final_product_moq_snapshot_20260722_product_id_idx" ON "cleanup_archive"."final_product_moq_snapshot_20260722" USING "btree" ("product_id");



CREATE UNIQUE INDEX "final_product_moq_snapshot_20_product_id_channel_customer_t_idx" ON "cleanup_archive"."final_product_moq_snapshot_20260722" USING "btree" ("product_id", "channel", "customer_type");



CREATE INDEX "final_product_pricing_snapshot_20260722_product_id_idx" ON "cleanup_archive"."final_product_pricing_snapshot_20260722" USING "btree" ("product_id");



CREATE UNIQUE INDEX "final_product_pricing_snapshot_202_product_id_price_channel_idx" ON "cleanup_archive"."final_product_pricing_snapshot_20260722" USING "btree" ("product_id", "price_channel");



CREATE INDEX "final_product_snapshot_20260722_department_idx" ON "cleanup_archive"."final_product_snapshot_20260722" USING "btree" ("department");



CREATE INDEX "final_whatsapp_drafts_snapshot_20260722_source_message_id_idx" ON "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722" USING "btree" ("source_message_id");



CREATE INDEX "final_whatsapp_drafts_snapshot_20260722_status_created_at_idx" ON "cleanup_archive"."final_whatsapp_drafts_snapshot_20260722" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "final_whatsapp_operator_decisi_source_message_id_decided_at_idx" ON "cleanup_archive"."final_whatsapp_operator_decisions_snapshot_20260722" USING "btree" ("source_message_id", "decided_at" DESC);



CREATE INDEX "order_snapshot_20260722_finance_verified_by_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("finance_verified_by");



CREATE INDEX "order_snapshot_20260722_is_duplicate_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("is_duplicate") WHERE ("is_duplicate" = true);



CREATE INDEX "order_snapshot_20260722_is_waste_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("is_waste") WHERE ("is_waste" = false);



CREATE INDEX "order_snapshot_20260722_needs_clarification_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("needs_clarification") WHERE ("needs_clarification" = true);



CREATE UNIQUE INDEX "order_snapshot_20260722_order_number_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("order_number");



CREATE INDEX "order_snapshot_20260722_payment_status_finance_verified_at_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("payment_status", "finance_verified_at" DESC);



CREATE UNIQUE INDEX "order_snapshot_20260722_wamid_idx" ON "cleanup_archive"."order_snapshot_20260722" USING "btree" ("wamid") WHERE ("wamid" IS NOT NULL);



CREATE INDEX "product_alias_snapshot_20260722_lower_idx" ON "cleanup_archive"."product_alias_snapshot_20260722" USING "btree" ("lower"("alias_text"));



CREATE INDEX "product_moq_rule_snapshot_20260722_product_id_idx" ON "cleanup_archive"."product_moq_rule_snapshot_20260722" USING "btree" ("product_id");



CREATE UNIQUE INDEX "product_moq_rule_snapshot_202_product_id_channel_customer_t_idx" ON "cleanup_archive"."product_moq_rule_snapshot_20260722" USING "btree" ("product_id", "channel", "customer_type");



CREATE INDEX "product_pricing_rule_snapshot_20260722_product_id_idx" ON "cleanup_archive"."product_pricing_rule_snapshot_20260722" USING "btree" ("product_id");



CREATE UNIQUE INDEX "product_pricing_rule_snapshot_2026_product_id_price_channel_idx" ON "cleanup_archive"."product_pricing_rule_snapshot_20260722" USING "btree" ("product_id", "price_channel");



CREATE INDEX "product_snapshot_20260722_department_idx" ON "cleanup_archive"."product_snapshot_20260722" USING "btree" ("department");



CREATE INDEX "dead_letter_application_workload_idx" ON "public"."dead_letter_entries" USING "btree" ("source_application", "workload_type", "created_at" DESC);



CREATE UNIQUE INDEX "dead_letter_open_source_uidx" ON "public"."dead_letter_entries" USING "btree" ("source_table", "source_record_id") WHERE ("status" = 'open'::"text");



CREATE INDEX "dead_letter_status_created_idx" ON "public"."dead_letter_entries" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "debug_webhooks_wamid_idx" ON "public"."debug_webhooks" USING "btree" ("wamid") WHERE ("wamid" IS NOT NULL);



CREATE INDEX "idx_auth_logs_created_at" ON "public"."auth_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_auth_logs_phone" ON "public"."auth_logs" USING "btree" ("phone");



CREATE INDEX "idx_b2b_applications_contact_email" ON "public"."b2b_applications" USING "btree" ("contact_email");



CREATE INDEX "idx_b2b_applications_contact_phone" ON "public"."b2b_applications" USING "btree" ("contact_phone");



CREATE INDEX "idx_b2b_applications_mobile_number" ON "public"."b2b_applications" USING "btree" ("mobile_number");



CREATE INDEX "idx_bml_company" ON "public"."bi_monthly_ledgers" USING "btree" ("company_id");



CREATE INDEX "idx_bml_period" ON "public"."bi_monthly_ledgers" USING "btree" ("period_start", "period_end");



CREATE INDEX "idx_catalogue_ai_studio_draft_audit_draft" ON "public"."catalogue_ai_studio_draft_audit_log" USING "btree" ("draft_id", "created_at" DESC);



CREATE INDEX "idx_catalogue_ai_studio_drafts_created_at" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "idx_catalogue_ai_studio_drafts_one_open_per_product" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("product_id") WHERE ("status" = ANY (ARRAY['DRAFT'::"text", 'UNDER_REVIEW'::"text"]));



CREATE INDEX "idx_catalogue_ai_studio_drafts_product" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("product_id", "version_number" DESC);



CREATE UNIQUE INDEX "idx_catalogue_ai_studio_drafts_product_version_unique" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("product_id", "version_number");



CREATE INDEX "idx_catalogue_ai_studio_drafts_status" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("status", "updated_at" DESC);



CREATE INDEX "idx_catalogue_ai_studio_drafts_updated_at" ON "public"."catalogue_ai_studio_drafts" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_catalogue_alias_drafts_created_at" ON "public"."catalogue_alias_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_alias_drafts_payload_gin" ON "public"."catalogue_alias_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_alias_drafts_status" ON "public"."catalogue_alias_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_alias_drafts_submitted_by" ON "public"."catalogue_alias_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_alias_drafts_target_record_id" ON "public"."catalogue_alias_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_approval_audit_created_at" ON "public"."catalogue_approval_audit" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_approval_audit_draft_id" ON "public"."catalogue_approval_audit" USING "btree" ("draft_id");



CREATE INDEX "idx_catalogue_approval_audit_draft_table" ON "public"."catalogue_approval_audit" USING "btree" ("draft_table");



CREATE INDEX "idx_catalogue_approval_audit_performed_by" ON "public"."catalogue_approval_audit" USING "btree" ("performed_by");



CREATE INDEX "idx_catalogue_bom_drafts_created_at" ON "public"."catalogue_bom_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_bom_drafts_payload_gin" ON "public"."catalogue_bom_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_bom_drafts_status" ON "public"."catalogue_bom_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_bom_drafts_submitted_by" ON "public"."catalogue_bom_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_bom_drafts_target_record_id" ON "public"."catalogue_bom_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_media_submissions_created_at" ON "public"."catalogue_media_submissions" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_media_submissions_payload_gin" ON "public"."catalogue_media_submissions" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_media_submissions_status" ON "public"."catalogue_media_submissions" USING "btree" ("status");



CREATE INDEX "idx_catalogue_media_submissions_submitted_by" ON "public"."catalogue_media_submissions" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_media_submissions_target_record_id" ON "public"."catalogue_media_submissions" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_moq_drafts_created_at" ON "public"."catalogue_moq_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_moq_drafts_payload_gin" ON "public"."catalogue_moq_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_moq_drafts_status" ON "public"."catalogue_moq_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_moq_drafts_submitted_by" ON "public"."catalogue_moq_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_moq_drafts_target_record_id" ON "public"."catalogue_moq_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_pricing_drafts_created_at" ON "public"."catalogue_pricing_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_pricing_drafts_payload_gin" ON "public"."catalogue_pricing_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_pricing_drafts_status" ON "public"."catalogue_pricing_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_pricing_drafts_submitted_by" ON "public"."catalogue_pricing_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_pricing_drafts_target_record_id" ON "public"."catalogue_pricing_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_product_drafts_created_at" ON "public"."catalogue_product_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_product_drafts_payload_gin" ON "public"."catalogue_product_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_product_drafts_status" ON "public"."catalogue_product_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_product_drafts_submitted_by" ON "public"."catalogue_product_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_product_drafts_target_record_id" ON "public"."catalogue_product_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_product_mappings_central_product" ON "public"."catalogue_product_mappings" USING "btree" ("central_product_id");



CREATE INDEX "idx_catalogue_product_mappings_last_synced" ON "public"."catalogue_product_mappings" USING "btree" ("last_synced_at" DESC NULLS LAST);



CREATE INDEX "idx_catalogue_product_mappings_sku" ON "public"."catalogue_product_mappings" USING "btree" ("sku");



CREATE INDEX "idx_catalogue_sync_events_version" ON "public"."catalogue_sync_events" USING "btree" ("catalogue_version_id", "triggered_at" DESC);



CREATE INDEX "idx_catalogue_tag_drafts_created_at" ON "public"."catalogue_tag_drafts" USING "btree" ("created_at");



CREATE INDEX "idx_catalogue_tag_drafts_payload_gin" ON "public"."catalogue_tag_drafts" USING "gin" ("payload");



CREATE INDEX "idx_catalogue_tag_drafts_status" ON "public"."catalogue_tag_drafts" USING "btree" ("status");



CREATE INDEX "idx_catalogue_tag_drafts_submitted_by" ON "public"."catalogue_tag_drafts" USING "btree" ("submitted_by");



CREATE INDEX "idx_catalogue_tag_drafts_target_record_id" ON "public"."catalogue_tag_drafts" USING "btree" ("target_record_id");



CREATE INDEX "idx_catalogue_versions_product_id" ON "public"."catalogue_versions" USING "btree" ("product_id", "version_number" DESC);



CREATE INDEX "idx_companies_is_frozen" ON "public"."companies" USING "btree" ("is_frozen") WHERE ("is_frozen" = true);



CREATE INDEX "idx_companies_phone" ON "public"."companies" USING "btree" ("phone");



CREATE INDEX "idx_crm_tasks_company" ON "public"."crm_tasks" USING "btree" ("company_id");



CREATE INDEX "idx_crm_tasks_exec" ON "public"."crm_tasks" USING "btree" ("sales_exec_id");



CREATE INDEX "idx_crm_tasks_status" ON "public"."crm_tasks" USING "btree" ("status", "due_date");



CREATE INDEX "idx_customer_import_batches_status" ON "public"."customer_import_batches" USING "btree" ("status", "loaded_at" DESC);



CREATE INDEX "idx_customer_import_company_batch_status" ON "public"."customer_import_company_candidates" USING "btree" ("batch_id", "validation_status");



CREATE INDEX "idx_customer_import_company_gst" ON "public"."customer_import_company_candidates" USING "btree" ("batch_id", "gst_number_normalized") WHERE ("gst_number_normalized" IS NOT NULL);



CREATE INDEX "idx_customer_import_company_phone" ON "public"."customer_import_company_candidates" USING "btree" ("batch_id", "phone_last10") WHERE ("phone_last10" IS NOT NULL);



CREATE INDEX "idx_customer_import_raw_batch_tab" ON "public"."customer_import_raw" USING "btree" ("batch_id", "source_tab", "source_row_number");



CREATE INDEX "idx_dispatch_completion_evidence_correlation" ON "public"."dispatch_completion_evidence" USING "btree" ("correlation_id");



CREATE INDEX "idx_dispatch_completion_evidence_order_id" ON "public"."dispatch_completion_evidence" USING "btree" ("order_id");



CREATE INDEX "idx_dispatch_readiness_evidence_correlation" ON "public"."dispatch_readiness_evidence" USING "btree" ("correlation_id");



CREATE INDEX "idx_dispatch_readiness_evidence_order_id" ON "public"."dispatch_readiness_evidence" USING "btree" ("order_id");



CREATE INDEX "idx_dispatch_release_lineage_correlation" ON "public"."dispatch_release_lineage" USING "btree" ("correlation_id");



CREATE INDEX "idx_dispatch_release_lineage_order_id" ON "public"."dispatch_release_lineage" USING "btree" ("order_id");



CREATE INDEX "idx_finance_review_evidence_order_id" ON "public"."finance_review_evidence" USING "btree" ("order_id");



CREATE INDEX "idx_inventory_movements_correlation_id" ON "public"."inventory_movements" USING "btree" ("correlation_id");



CREATE INDEX "idx_inventory_movements_product_sku" ON "public"."inventory_movements" USING "btree" ("product_id", "sku", "created_at" DESC);



CREATE INDEX "idx_inventory_movements_reservation_id" ON "public"."inventory_movements" USING "btree" ("reservation_id") WHERE ("reservation_id" IS NOT NULL);



CREATE UNIQUE INDEX "idx_inventory_reservation_allocations_entity_active" ON "public"."inventory_reservation_allocations" USING "btree" ("reservation_id", "inventory_entity_type", "inventory_entity_id") WHERE ("allocation_status" = 'active'::"text");



CREATE INDEX "idx_inventory_reservation_allocations_reservation" ON "public"."inventory_reservation_allocations" USING "btree" ("reservation_id");



CREATE INDEX "idx_inventory_reservations_expires_at" ON "public"."inventory_reservations" USING "btree" ("expires_at") WHERE ("expires_at" IS NOT NULL);



CREATE INDEX "idx_inventory_reservations_order_id" ON "public"."inventory_reservations" USING "btree" ("order_id");



CREATE INDEX "idx_inventory_reservations_product_sku" ON "public"."inventory_reservations" USING "btree" ("product_id", "sku");



CREATE INDEX "idx_inventory_reservations_queue_item" ON "public"."inventory_reservations" USING "btree" ("queue_item_id") WHERE ("queue_item_id" IS NOT NULL);



CREATE INDEX "idx_inventory_reservations_status" ON "public"."inventory_reservations" USING "btree" ("reservation_status");



CREATE INDEX "idx_inventory_stock_balances_location" ON "public"."inventory_stock_balances" USING "btree" ("location_code");



CREATE INDEX "idx_inventory_stock_balances_product_sku" ON "public"."inventory_stock_balances" USING "btree" ("product_id", "sku");



CREATE INDEX "idx_ld_ledger" ON "public"."ledger_disputes" USING "btree" ("ledger_id");



CREATE INDEX "idx_ld_status" ON "public"."ledger_disputes" USING "btree" ("status");



CREATE INDEX "idx_operational_events_correlation_id" ON "public"."operational_events" USING "btree" ("correlation_id");



CREATE INDEX "idx_operational_events_entity_created" ON "public"."operational_events" USING "btree" ("entity_type", "entity_id", "created_at" DESC);



CREATE UNIQUE INDEX "idx_operational_events_idempotency_key" ON "public"."operational_events" USING "btree" ("idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "idx_operational_events_order_created" ON "public"."operational_events" USING "btree" ("order_id", "created_at" DESC) WHERE ("order_id" IS NOT NULL);



CREATE INDEX "idx_operational_events_queue_item_created" ON "public"."operational_events" USING "btree" ("queue_item_id", "created_at" DESC) WHERE ("queue_item_id" IS NOT NULL);



CREATE INDEX "idx_operational_queue_assignments_item" ON "public"."operational_queue_assignments" USING "btree" ("queue_item_id", "assigned_at" DESC);



CREATE INDEX "idx_operational_queue_items_assigned_to" ON "public"."operational_queue_items" USING "btree" ("assigned_to") WHERE ("assigned_to" IS NOT NULL);



CREATE INDEX "idx_operational_queue_items_order_id" ON "public"."operational_queue_items" USING "btree" ("order_id") WHERE ("order_id" IS NOT NULL);



CREATE INDEX "idx_operational_queue_items_owner_department" ON "public"."operational_queue_items" USING "btree" ("owner_department") WHERE ("owner_department" IS NOT NULL);



CREATE INDEX "idx_operational_queue_items_queue_state" ON "public"."operational_queue_items" USING "btree" ("queue_type", "state");



CREATE INDEX "idx_operational_queue_items_sla_due_at" ON "public"."operational_queue_items" USING "btree" ("sla_due_at") WHERE ("sla_due_at" IS NOT NULL);



CREATE UNIQUE INDEX "idx_operational_queue_items_source_entity" ON "public"."operational_queue_items" USING "btree" ("source", "queue_type", "entity_type", "entity_id") WHERE ("state" <> ALL (ARRAY['completed'::"text", 'cancelled'::"text"]));



CREATE INDEX "idx_operational_scan_records_barcode_value" ON "public"."operational_scan_records" USING "btree" ("barcode_value");



CREATE INDEX "idx_operational_scan_records_correlation_id" ON "public"."operational_scan_records" USING "btree" ("correlation_id");



CREATE INDEX "idx_operational_scan_records_created_at" ON "public"."operational_scan_records" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_operational_scan_records_duplicate_window" ON "public"."operational_scan_records" USING "btree" ("barcode_value", "entity_type", "entity_id", "verification_type", "created_at" DESC);



CREATE UNIQUE INDEX "idx_operational_scan_records_idempotency_key" ON "public"."operational_scan_records" USING "btree" ("idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "idx_operational_scan_records_order_id" ON "public"."operational_scan_records" USING "btree" ("order_id") WHERE ("order_id" IS NOT NULL);



CREATE INDEX "idx_operational_scan_records_queue_item_id" ON "public"."operational_scan_records" USING "btree" ("queue_item_id") WHERE ("queue_item_id" IS NOT NULL);



CREATE INDEX "idx_operational_scan_records_verification_status" ON "public"."operational_scan_records" USING "btree" ("verification_status");



CREATE INDEX "idx_operational_search_index_aliases" ON "public"."operational_search_index" USING "gin" ("aliases");



CREATE INDEX "idx_operational_search_index_barcode_values" ON "public"."operational_search_index" USING "gin" ("barcode_values");



CREATE INDEX "idx_operational_search_index_customer_id" ON "public"."operational_search_index" USING "btree" ("customer_id") WHERE ("customer_id" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_department" ON "public"."operational_search_index" USING "btree" ("department") WHERE ("department" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_entity_type" ON "public"."operational_search_index" USING "btree" ("entity_type");



CREATE INDEX "idx_operational_search_index_event_id" ON "public"."operational_search_index" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_normalized_tokens" ON "public"."operational_search_index" USING "gin" ("normalized_tokens");



CREATE INDEX "idx_operational_search_index_order_id" ON "public"."operational_search_index" USING "btree" ("order_id") WHERE ("order_id" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_queue_item_id" ON "public"."operational_search_index" USING "btree" ("queue_item_id") WHERE ("queue_item_id" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_scan_record_id" ON "public"."operational_search_index" USING "btree" ("scan_record_id") WHERE ("scan_record_id" IS NOT NULL);



CREATE INDEX "idx_operational_search_index_so_numbers" ON "public"."operational_search_index" USING "gin" ("so_numbers");



CREATE INDEX "idx_operational_search_index_updated_at" ON "public"."operational_search_index" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_operational_search_index_visibility" ON "public"."operational_search_index" USING "btree" ("visibility");



CREATE INDEX "idx_order_payments_order_status" ON "public"."order_payments" USING "btree" ("order_id", "status");



CREATE INDEX "idx_order_payments_status" ON "public"."order_payments" USING "btree" ("status");



CREATE INDEX "idx_order_payments_verified_by" ON "public"."order_payments" USING "btree" ("verified_by");



CREATE INDEX "idx_orders_finance_verified_by" ON "public"."orders" USING "btree" ("finance_verified_by");



CREATE INDEX "idx_orders_is_waste" ON "public"."orders" USING "btree" ("is_waste") WHERE ("is_waste" = false);



CREATE INDEX "idx_orders_needs_clarification" ON "public"."orders" USING "btree" ("needs_clarification") WHERE ("needs_clarification" = true);



CREATE INDEX "idx_orders_payment_status_finance" ON "public"."orders" USING "btree" ("payment_status", "finance_verified_at" DESC);



CREATE INDEX "idx_product_aliases_alias" ON "public"."product_aliases" USING "btree" ("lower"("alias_text"));



CREATE INDEX "idx_product_bom_product_type" ON "public"."product_bom" USING "btree" ("product_id", "bom_type");



CREATE INDEX "idx_product_media_product_id" ON "public"."product_media" USING "btree" ("product_id");



CREATE INDEX "idx_product_moq_rules_product_id" ON "public"."product_moq_rules" USING "btree" ("product_id");



CREATE INDEX "idx_product_pricing_rules_product_id" ON "public"."product_pricing_rules" USING "btree" ("product_id");



CREATE INDEX "idx_product_variants_product_id" ON "public"."product_variants" USING "btree" ("product_id");



CREATE INDEX "idx_production_jobs_department" ON "public"."production_jobs" USING "btree" ("department");



CREATE INDEX "idx_production_jobs_status" ON "public"."production_jobs" USING "btree" ("status");



CREATE INDEX "idx_products_department" ON "public"."products" USING "btree" ("department");



CREATE INDEX "idx_sales_order_draft_audit_draft" ON "public"."sales_order_draft_audit_log" USING "btree" ("draft_id", "created_at" DESC);



CREATE INDEX "idx_sales_order_draft_lines_draft" ON "public"."sales_order_draft_lines" USING "btree" ("draft_id", "line_index");



CREATE INDEX "idx_sales_order_drafts_packet" ON "public"."sales_order_drafts" USING "btree" ("packet_id", "created_at" DESC);



CREATE UNIQUE INDEX "idx_sales_order_drafts_packet_active" ON "public"."sales_order_drafts" USING "btree" ("packet_id") WHERE ("status" = ANY (ARRAY['AI_DRAFT'::"text", 'UNDER_REVIEW'::"text", 'APPROVED_FOR_SO'::"text"]));



CREATE INDEX "idx_sales_order_drafts_status" ON "public"."sales_order_drafts" USING "btree" ("status", "updated_at" DESC);



CREATE UNIQUE INDEX "idx_shadow_clients_phone" ON "public"."shadow_clients" USING "btree" ("sender_phone");



CREATE INDEX "idx_shadow_clients_status" ON "public"."shadow_clients" USING "btree" ("status");



CREATE INDEX "idx_sku_code_rules_active_sort" ON "public"."sku_code_rules" USING "btree" ("code_type", "is_active", "sort_order");



CREATE INDEX "idx_stock_consumption_lineage_order" ON "public"."stock_consumption_lineage" USING "btree" ("order_id", "created_at" DESC);



CREATE INDEX "idx_stock_consumption_lineage_reservation" ON "public"."stock_consumption_lineage" USING "btree" ("reservation_id") WHERE ("reservation_id" IS NOT NULL);



CREATE INDEX "idx_suggested_orders_company" ON "public"."suggested_orders" USING "btree" ("matched_company_id");



CREATE INDEX "idx_suggested_orders_status" ON "public"."suggested_orders" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_users_email" ON "public"."users" USING "btree" ("email");



CREATE INDEX "idx_users_phone" ON "public"."users" USING "btree" ("phone");



CREATE INDEX "idx_users_secondary_phones" ON "public"."users" USING "gin" ("secondary_phones");



CREATE INDEX "idx_whatsapp_automations_order" ON "public"."whatsapp_automations" USING "btree" ("order_id");



CREATE INDEX "idx_whatsapp_automations_status" ON "public"."whatsapp_automations" USING "btree" ("status");



CREATE INDEX "idx_whatsapp_automations_trigger" ON "public"."whatsapp_automations" USING "btree" ("trigger_type");



CREATE INDEX "idx_whatsapp_buffer_sender" ON "public"."whatsapp_buffer" USING "btree" ("sender_phone", "created_at");



CREATE INDEX "idx_whatsapp_buffer_status" ON "public"."whatsapp_buffer" USING "btree" ("bundle_status");



CREATE INDEX "idx_whatsapp_contacts_phone" ON "public"."whatsapp_contacts" USING "btree" ("phone_number");



CREATE INDEX "idx_whatsapp_inbound_messages_received_at" ON "public"."whatsapp_inbound_messages" USING "btree" ("received_at" DESC);



CREATE INDEX "idx_whatsapp_inbound_messages_sender_phone" ON "public"."whatsapp_inbound_messages" USING "btree" ("sender_phone");



CREATE INDEX "idx_whatsapp_messages_contact" ON "public"."whatsapp_messages" USING "btree" ("contact_id");



CREATE INDEX "idx_whatsapp_messages_contact_created" ON "public"."whatsapp_messages" USING "btree" ("contact_id", "created_at" DESC);



CREATE INDEX "idx_whatsapp_messages_is_raw" ON "public"."whatsapp_messages" USING "btree" ("is_raw");



CREATE INDEX "idx_whatsapp_messages_order" ON "public"."whatsapp_messages" USING "btree" ("order_id");



CREATE INDEX "idx_whatsapp_messages_packet_id" ON "public"."whatsapp_messages" USING "btree" ("packet_id");



CREATE INDEX "idx_whatsapp_messages_provider" ON "public"."whatsapp_messages" USING "btree" ("provider");



CREATE INDEX "idx_whatsapp_messages_status" ON "public"."whatsapp_messages" USING "btree" ("status");



CREATE INDEX "idx_whatsapp_operator_decisions_message" ON "public"."whatsapp_operator_decisions" USING "btree" ("source_message_id", "decided_at" DESC);



CREATE INDEX "idx_whatsapp_override_log_created" ON "public"."whatsapp_override_log" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_whatsapp_override_log_operator" ON "public"."whatsapp_override_log" USING "btree" ("operator_id");



CREATE INDEX "idx_whatsapp_override_log_packet" ON "public"."whatsapp_override_log" USING "btree" ("packet_id");



CREATE INDEX "idx_whatsapp_packets_contact" ON "public"."whatsapp_stitched_packets" USING "btree" ("contact_id");



CREATE INDEX "idx_whatsapp_packets_contact_sequence" ON "public"."whatsapp_stitched_packets" USING "btree" ("contact_id", "packet_sequence");



CREATE INDEX "idx_whatsapp_packets_created" ON "public"."whatsapp_stitched_packets" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_whatsapp_packets_status" ON "public"."whatsapp_stitched_packets" USING "btree" ("status");



CREATE INDEX "idx_whatsapp_sales_order_drafts_source_message" ON "public"."whatsapp_sales_order_drafts" USING "btree" ("source_message_id");



CREATE INDEX "idx_whatsapp_sales_order_drafts_status" ON "public"."whatsapp_sales_order_drafts" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_whatsapp_suggestions_created" ON "public"."whatsapp_suggestions_log" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_whatsapp_suggestions_packet" ON "public"."whatsapp_suggestions_log" USING "btree" ("packet_id");



CREATE INDEX "idx_whatsapp_suggestions_type" ON "public"."whatsapp_suggestions_log" USING "btree" ("suggestion_type");



CREATE INDEX "notification_outbox_claim_idx" ON "public"."notification_outbox" USING "btree" ("status", "next_attempt_at", "priority", "created_at") WHERE ("status" = ANY (ARRAY['pending'::"text", 'retry'::"text"]));



CREATE INDEX "notification_outbox_event_idx" ON "public"."notification_outbox" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE UNIQUE INDEX "notification_outbox_source_idempotency_uidx" ON "public"."notification_outbox" USING "btree" ("source_application", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE UNIQUE INDEX "ols_carton_contents_active_label_uniq" ON "public"."ols_carton_contents" USING "btree" ("production_label_id") WHERE ("production_label_id" IS NOT NULL);



CREATE INDEX "operational_events_causation_idx" ON "public"."operational_events" USING "btree" ("causation_id") WHERE ("causation_id" IS NOT NULL);



CREATE INDEX "operational_events_correlation_idx" ON "public"."operational_events" USING "btree" ("correlation_id", "occurred_at" DESC);



CREATE INDEX "operational_events_entity_timeline_idx" ON "public"."operational_events" USING "btree" ("entity_type", "entity_id", "occurred_at" DESC);



CREATE UNIQUE INDEX "operational_events_source_idempotency_uidx" ON "public"."operational_events" USING "btree" ("source_application", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "orders_is_duplicate_idx" ON "public"."orders" USING "btree" ("is_duplicate") WHERE ("is_duplicate" = true);



CREATE UNIQUE INDEX "orders_order_number_key" ON "public"."orders" USING "btree" ("order_number");



CREATE UNIQUE INDEX "orders_wamid_unique_idx" ON "public"."orders" USING "btree" ("wamid") WHERE ("wamid" IS NOT NULL);



CREATE UNIQUE INDEX "org_branches_company_code_uidx" ON "public"."org_branches" USING "btree" ("company_id", "branch_code") WHERE ("branch_code" IS NOT NULL);



CREATE UNIQUE INDEX "org_companies_external_ref_uidx" ON "public"."org_companies" USING "btree" ("external_ref") WHERE ("external_ref" IS NOT NULL);



CREATE UNIQUE INDEX "org_contacts_email_uidx" ON "public"."org_contacts" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE UNIQUE INDEX "org_memberships_company_contact_uidx" ON "public"."org_memberships" USING "btree" ("company_id", "contact_id") WHERE (("contact_id" IS NOT NULL) AND ("status" <> 'ended'::"text"));



CREATE UNIQUE INDEX "org_memberships_company_user_uidx" ON "public"."org_memberships" USING "btree" ("company_id", "user_id") WHERE (("user_id" IS NOT NULL) AND ("status" <> 'ended'::"text"));



CREATE INDEX "support_tickets_company_created_idx" ON "public"."support_tickets" USING "btree" ("company_id", "created_at" DESC);



CREATE INDEX "support_tickets_order_id_idx" ON "public"."support_tickets" USING "btree" ("order_id");



CREATE UNIQUE INDEX "uq_b2b_applications_email_mobile" ON "public"."b2b_applications" USING "btree" ("lower"("contact_email"), "mobile_number") WHERE (("contact_email" IS NOT NULL) AND ("mobile_number" IS NOT NULL));



CREATE UNIQUE INDEX "uq_product_moq_rules_product_channel_customer" ON "public"."product_moq_rules" USING "btree" ("product_id", "channel", "customer_type");



CREATE UNIQUE INDEX "uq_product_pricing_rules_product_channel" ON "public"."product_pricing_rules" USING "btree" ("product_id", "price_channel");



CREATE INDEX "user_role_map_role_id_idx" ON "public"."user_role_map" USING "btree" ("role_id");



CREATE INDEX "user_role_map_user_id_idx" ON "public"."user_role_map" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "guard_is_frozen_manual" BEFORE UPDATE OF "is_frozen" ON "public"."companies" FOR EACH ROW EXECUTE FUNCTION "public"."guard_companies_is_frozen"();



CREATE OR REPLACE TRIGGER "guard_order_status_regression" BEFORE UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_order_status_regression"();



CREATE OR REPLACE TRIGGER "orders_assign_order_number_bi" BEFORE INSERT ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."assign_order_number_on_insert"();



CREATE OR REPLACE TRIGGER "set_order_tracking_token" BEFORE INSERT ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."generate_order_tracking_token"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_cartons" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_finance_pi" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_label_templates" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_printer_settings" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_printers" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_production_labels" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_profiles_light" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_reprint_requests" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."ols_settings" FOR EACH ROW EXECUTE FUNCTION "public"."ols_set_updated_at"();



CREATE OR REPLACE TRIGGER "support_ticket_customer_context_trg" BEFORE INSERT OR UPDATE ON "public"."support_tickets" FOR EACH ROW EXECUTE FUNCTION "public"."support_ticket_set_customer_context"();



CREATE OR REPLACE TRIGGER "trg_access_permissions_updated_at" BEFORE UPDATE ON "public"."access_permissions" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_activate_company_on_approval" AFTER INSERT OR UPDATE OF "status" ON "public"."b2b_applications" FOR EACH ROW EXECUTE FUNCTION "public"."activate_company_on_application_approval"();



CREATE OR REPLACE TRIGGER "trg_block_orders_frozen" BEFORE INSERT OR UPDATE OF "status" ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."block_orders_when_frozen"();



CREATE OR REPLACE TRIGGER "trg_catalogue_ai_studio_drafts_touch" BEFORE UPDATE ON "public"."catalogue_ai_studio_drafts" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_credit_payment" AFTER INSERT ON "public"."order_payments" FOR EACH ROW EXECUTE FUNCTION "public"."handle_credit_payment"();



CREATE OR REPLACE TRIGGER "trg_dispatch_completion_evidence_no_delete" BEFORE DELETE ON "public"."dispatch_completion_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_completion_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_dispatch_completion_evidence_no_update" BEFORE UPDATE ON "public"."dispatch_completion_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_completion_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_dispatch_readiness_evidence_no_delete" BEFORE DELETE ON "public"."dispatch_readiness_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_readiness_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_dispatch_readiness_evidence_no_update" BEFORE UPDATE ON "public"."dispatch_readiness_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_readiness_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_dispatch_release_lineage_no_delete" BEFORE DELETE ON "public"."dispatch_release_lineage" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_release_lineage_immutable"();



CREATE OR REPLACE TRIGGER "trg_dispatch_release_lineage_no_update" BEFORE UPDATE ON "public"."dispatch_release_lineage" FOR EACH ROW EXECUTE FUNCTION "public"."dispatch_release_lineage_immutable"();



CREATE OR REPLACE TRIGGER "trg_finance_review_evidence_no_delete" BEFORE DELETE ON "public"."finance_review_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."finance_review_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_finance_review_evidence_no_update" BEFORE UPDATE ON "public"."finance_review_evidence" FOR EACH ROW EXECUTE FUNCTION "public"."finance_review_evidence_immutable"();



CREATE OR REPLACE TRIGGER "trg_guard_is_frozen" BEFORE UPDATE OF "is_frozen" ON "public"."companies" FOR EACH ROW EXECUTE FUNCTION "public"."guard_is_frozen_changes"();



CREATE OR REPLACE TRIGGER "trg_identity_profiles_updated_at" BEFORE UPDATE ON "public"."identity_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_inventory_movements_no_delete" BEFORE DELETE ON "public"."inventory_movements" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_inventory_movement_mutation"();



CREATE OR REPLACE TRIGGER "trg_inventory_movements_no_update" BEFORE UPDATE ON "public"."inventory_movements" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_inventory_movement_mutation"();



CREATE OR REPLACE TRIGGER "trg_link_buyer_on_approval" AFTER INSERT OR UPDATE OF "status" ON "public"."b2b_applications" FOR EACH ROW EXECUTE FUNCTION "public"."link_buyer_on_application_approval"();



CREATE OR REPLACE TRIGGER "trg_notify_admin_new_application" AFTER INSERT ON "public"."b2b_applications" FOR EACH ROW EXECUTE FUNCTION "public"."notify_admin_new_b2b_application"();



CREATE OR REPLACE TRIGGER "trg_operational_events_no_delete" BEFORE DELETE ON "public"."operational_events" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_operational_event_mutation"();



CREATE OR REPLACE TRIGGER "trg_operational_events_no_update" BEFORE UPDATE ON "public"."operational_events" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_operational_event_mutation"();



CREATE OR REPLACE TRIGGER "trg_operational_scan_records_no_delete" BEFORE DELETE ON "public"."operational_scan_records" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_operational_scan_mutation"();



CREATE OR REPLACE TRIGGER "trg_operational_scan_records_no_update" BEFORE UPDATE ON "public"."operational_scan_records" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_operational_scan_mutation"();



CREATE OR REPLACE TRIGGER "trg_org_branches_updated_at" BEFORE UPDATE ON "public"."org_branches" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_org_companies_updated_at" BEFORE UPDATE ON "public"."org_companies" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_org_contacts_updated_at" BEFORE UPDATE ON "public"."org_contacts" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_org_memberships_updated_at" BEFORE UPDATE ON "public"."org_memberships" FOR EACH ROW EXECUTE FUNCTION "public"."app_verse_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_outstanding_on_order" AFTER INSERT OR UPDATE OF "status", "sales_order_value" ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."update_outstanding_on_order"();



CREATE OR REPLACE TRIGGER "trg_prevent_profile_priv_esc" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_profile_privilege_escalation"();



CREATE OR REPLACE TRIGGER "trg_profiles_enforce_profile_approval_for_staff" BEFORE INSERT OR UPDATE OF "role", "is_approved", "status" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_profile_approval_for_staff"();



CREATE OR REPLACE TRIGGER "trg_sales_order_draft_lines_touch" BEFORE UPDATE ON "public"."sales_order_draft_lines" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sales_order_drafts_immutable_fields" BEFORE UPDATE ON "public"."sales_order_drafts" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_sales_order_draft_immutable_fields"();



CREATE OR REPLACE TRIGGER "trg_sales_order_drafts_touch" BEFORE UPDATE ON "public"."sales_order_drafts" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_shadow_clients_touch" BEFORE UPDATE ON "public"."shadow_clients" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_starter_packs_updated_at" BEFORE UPDATE ON "public"."starter_packs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_starter_packs_updated_at"();



CREATE OR REPLACE TRIGGER "trg_stock_consumption_lineage_no_delete" BEFORE DELETE ON "public"."stock_consumption_lineage" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_stock_consumption_lineage_mutation"();



CREATE OR REPLACE TRIGGER "trg_stock_consumption_lineage_no_update" BEFORE UPDATE ON "public"."stock_consumption_lineage" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_stock_consumption_lineage_mutation"();



CREATE OR REPLACE TRIGGER "trg_suggested_orders_touch" BEFORE UPDATE ON "public"."suggested_orders" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_erp_financials" AFTER INSERT OR DELETE OR UPDATE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."recalculate_erp_order_financials"();



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."b2b_applications"
    ADD CONSTRAINT "b2b_applications_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."b2b_applications"
    ADD CONSTRAINT "b2b_applications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bi_monthly_ledgers"
    ADD CONSTRAINT "bi_monthly_ledgers_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."catalogue_ai_studio_draft_audit_log"
    ADD CONSTRAINT "catalogue_ai_studio_draft_audit_log_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."catalogue_ai_studio_drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."catalogue_ai_studio_drafts"
    ADD CONSTRAINT "catalogue_ai_studio_drafts_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."catalogue_alias_drafts"
    ADD CONSTRAINT "catalogue_alias_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_alias_drafts"
    ADD CONSTRAINT "catalogue_alias_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_approval_audit"
    ADD CONSTRAINT "catalogue_approval_audit_performed_by_fkey" FOREIGN KEY ("performed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_bom_drafts"
    ADD CONSTRAINT "catalogue_bom_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_bom_drafts"
    ADD CONSTRAINT "catalogue_bom_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_media_submissions"
    ADD CONSTRAINT "catalogue_media_submissions_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_media_submissions"
    ADD CONSTRAINT "catalogue_media_submissions_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_moq_drafts"
    ADD CONSTRAINT "catalogue_moq_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_moq_drafts"
    ADD CONSTRAINT "catalogue_moq_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_pricing_drafts"
    ADD CONSTRAINT "catalogue_pricing_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_pricing_drafts"
    ADD CONSTRAINT "catalogue_pricing_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_product_drafts"
    ADD CONSTRAINT "catalogue_product_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_product_drafts"
    ADD CONSTRAINT "catalogue_product_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_product_mappings"
    ADD CONSTRAINT "catalogue_product_mappings_central_product_id_fkey" FOREIGN KEY ("central_product_id") REFERENCES "public"."products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."catalogue_sync_events"
    ADD CONSTRAINT "catalogue_sync_events_catalogue_version_id_fkey" FOREIGN KEY ("catalogue_version_id") REFERENCES "public"."catalogue_versions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."catalogue_tag_drafts"
    ADD CONSTRAINT "catalogue_tag_drafts_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_tag_drafts"
    ADD CONSTRAINT "catalogue_tag_drafts_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."catalogue_versions"
    ADD CONSTRAINT "catalogue_versions_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."client_interactions"
    ADD CONSTRAINT "client_interactions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_interactions"
    ADD CONSTRAINT "client_interactions_executive_id_fkey" FOREIGN KEY ("executive_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."commission_payouts"
    ADD CONSTRAINT "commission_payouts_executive_id_fkey" FOREIGN KEY ("executive_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."commission_payouts"
    ADD CONSTRAINT "commission_payouts_paid_by_fkey" FOREIGN KEY ("paid_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_account_manager_id_fkey" FOREIGN KEY ("account_manager_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."credit_requests"
    ADD CONSTRAINT "credit_requests_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."credit_requests"
    ADD CONSTRAINT "credit_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."credit_rescue_events"
    ADD CONSTRAINT "credit_rescue_events_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crm_tasks"
    ADD CONSTRAINT "crm_tasks_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crm_tasks"
    ADD CONSTRAINT "crm_tasks_sales_exec_id_fkey" FOREIGN KEY ("sales_exec_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."customer_import_company_candidates"
    ADD CONSTRAINT "customer_import_company_candidates_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."customer_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_import_company_candidates"
    ADD CONSTRAINT "customer_import_company_candidates_raw_id_fkey" FOREIGN KEY ("raw_id") REFERENCES "public"."customer_import_raw"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."customer_import_contact_candidates"
    ADD CONSTRAINT "customer_import_contact_candidates_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."customer_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_import_contact_candidates"
    ADD CONSTRAINT "customer_import_contact_candidates_company_candidate_id_fkey" FOREIGN KEY ("company_candidate_id") REFERENCES "public"."customer_import_company_candidates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."customer_import_contact_candidates"
    ADD CONSTRAINT "customer_import_contact_candidates_raw_id_fkey" FOREIGN KEY ("raw_id") REFERENCES "public"."customer_import_raw"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."customer_import_duplicate_review"
    ADD CONSTRAINT "customer_import_duplicate_review_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."customer_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_import_duplicate_review"
    ADD CONSTRAINT "customer_import_duplicate_review_raw_id_fkey" FOREIGN KEY ("raw_id") REFERENCES "public"."customer_import_raw"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."customer_import_raw"
    ADD CONSTRAINT "customer_import_raw_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."customer_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_logs"
    ADD CONSTRAINT "daily_production_logs_logged_by_fkey" FOREIGN KEY ("logged_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."daily_production_logs"
    ADD CONSTRAINT "daily_production_logs_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."dead_letter_entries"
    ADD CONSTRAINT "dead_letter_entries_policy_key_fkey" FOREIGN KEY ("policy_key") REFERENCES "public"."retry_policies"("policy_key");



ALTER TABLE ONLY "public"."delivery_addresses"
    ADD CONSTRAINT "delivery_addresses_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dispatch_cartons"
    ADD CONSTRAINT "dispatch_cartons_dispatch_id_fkey" FOREIGN KEY ("dispatch_id") REFERENCES "public"."dispatches"("id");



ALTER TABLE ONLY "public"."dispatch_cartons"
    ADD CONSTRAINT "dispatch_cartons_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."dispatches"
    ADD CONSTRAINT "dispatches_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_dispatch_id_fkey" FOREIGN KEY ("dispatch_id") REFERENCES "public"."dispatches"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_performance_logs"
    ADD CONSTRAINT "employee_performance_logs_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."exchange_rates"
    ADD CONSTRAINT "exchange_rates_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."factory_inventory"
    ADD CONSTRAINT "factory_inventory_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_messages"
    ADD CONSTRAINT "fk_whatsapp_messages_packet_id" FOREIGN KEY ("packet_id") REFERENCES "public"."whatsapp_message_packets"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."freight_ledger"
    ADD CONSTRAINT "freight_ledger_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."identity_profiles"
    ADD CONSTRAINT "identity_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_adjustments"
    ADD CONSTRAINT "inventory_adjustments_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_reservation_id_fkey" FOREIGN KEY ("reservation_id") REFERENCES "public"."inventory_reservations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."inventory_reservation_allocations"
    ADD CONSTRAINT "inventory_reservation_allocations_reservation_id_fkey" FOREIGN KEY ("reservation_id") REFERENCES "public"."inventory_reservations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."inventory_reservations"
    ADD CONSTRAINT "inventory_reservations_queue_item_id_fkey" FOREIGN KEY ("queue_item_id") REFERENCES "public"."operational_queue_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_dispatch_id_fkey" FOREIGN KEY ("dispatch_id") REFERENCES "public"."dispatches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inward_material_advice"
    ADD CONSTRAINT "inward_material_advice_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."inward_material_advice"
    ADD CONSTRAINT "inward_material_advice_sales_exec_id_fkey" FOREIGN KEY ("sales_exec_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."inward_material_items"
    ADD CONSTRAINT "inward_material_items_advice_id_fkey" FOREIGN KEY ("advice_id") REFERENCES "public"."inward_material_advice"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inward_material_items"
    ADD CONSTRAINT "inward_material_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."ledger_disputes"
    ADD CONSTRAINT "ledger_disputes_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ledger_disputes"
    ADD CONSTRAINT "ledger_disputes_ledger_id_fkey" FOREIGN KEY ("ledger_id") REFERENCES "public"."bi_monthly_ledgers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."moq_rules"
    ADD CONSTRAINT "moq_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_carton_contents"
    ADD CONSTRAINT "ols_carton_contents_carton_id_fkey" FOREIGN KEY ("carton_id") REFERENCES "public"."ols_cartons"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_carton_contents"
    ADD CONSTRAINT "ols_carton_contents_production_label_id_fkey" FOREIGN KEY ("production_label_id") REFERENCES "public"."ols_production_labels"("id");



ALTER TABLE ONLY "public"."ols_dispatch_document_bundles"
    ADD CONSTRAINT "ols_dispatch_document_bundles_dpl_id_fkey" FOREIGN KEY ("dpl_id") REFERENCES "public"."ols_dpl_documents"("id");



ALTER TABLE ONLY "public"."ols_dispatch_document_bundles"
    ADD CONSTRAINT "ols_dispatch_document_bundles_pi_id_fkey" FOREIGN KEY ("pi_id") REFERENCES "public"."ols_finance_pi"("id");



ALTER TABLE ONLY "public"."ols_dpl_cartons"
    ADD CONSTRAINT "ols_dpl_cartons_carton_id_fkey" FOREIGN KEY ("carton_id") REFERENCES "public"."ols_cartons"("id");



ALTER TABLE ONLY "public"."ols_dpl_cartons"
    ADD CONSTRAINT "ols_dpl_cartons_dpl_id_fkey" FOREIGN KEY ("dpl_id") REFERENCES "public"."ols_dpl_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_finance_pi_cartons"
    ADD CONSTRAINT "ols_finance_pi_cartons_carton_id_fkey" FOREIGN KEY ("carton_id") REFERENCES "public"."ols_cartons"("id");



ALTER TABLE ONLY "public"."ols_finance_pi_cartons"
    ADD CONSTRAINT "ols_finance_pi_cartons_pi_id_fkey" FOREIGN KEY ("pi_id") REFERENCES "public"."ols_finance_pi"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_finance_pi"
    ADD CONSTRAINT "ols_finance_pi_dpl_id_fkey" FOREIGN KEY ("dpl_id") REFERENCES "public"."ols_dpl_documents"("id");



ALTER TABLE ONLY "public"."ols_finance_pi_lines"
    ADD CONSTRAINT "ols_finance_pi_lines_pi_id_fkey" FOREIGN KEY ("pi_id") REFERENCES "public"."ols_finance_pi"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_gate_scans"
    ADD CONSTRAINT "ols_gate_scans_shipping_label_id_fkey" FOREIGN KEY ("shipping_label_id") REFERENCES "public"."ols_shipping_labels"("id");



ALTER TABLE ONLY "public"."ols_inventory_movements"
    ADD CONSTRAINT "ols_inventory_movements_production_label_id_fkey" FOREIGN KEY ("production_label_id") REFERENCES "public"."ols_production_labels"("id");



ALTER TABLE ONLY "public"."ols_print_jobs"
    ADD CONSTRAINT "ols_print_jobs_printer_id_fkey" FOREIGN KEY ("printer_id") REFERENCES "public"."ols_printers"("id");



ALTER TABLE ONLY "public"."ols_print_jobs"
    ADD CONSTRAINT "ols_print_jobs_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."ols_label_templates"("id");



ALTER TABLE ONLY "public"."ols_print_logs"
    ADD CONSTRAINT "ols_print_logs_printer_id_fkey" FOREIGN KEY ("printer_id") REFERENCES "public"."ols_printers"("id");



ALTER TABLE ONLY "public"."ols_printer_settings"
    ADD CONSTRAINT "ols_printer_settings_printer_id_fkey" FOREIGN KEY ("printer_id") REFERENCES "public"."ols_printers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ols_production_batches"
    ADD CONSTRAINT "ols_production_batches_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."ols_departments"("id");



ALTER TABLE ONLY "public"."ols_production_batches"
    ADD CONSTRAINT "ols_production_batches_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."ols_products_cache"("id");



ALTER TABLE ONLY "public"."ols_production_labels"
    ADD CONSTRAINT "ols_production_labels_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."ols_production_batches"("id");



ALTER TABLE ONLY "public"."ols_production_labels"
    ADD CONSTRAINT "ols_production_labels_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."ols_departments"("id");



ALTER TABLE ONLY "public"."ols_production_labels"
    ADD CONSTRAINT "ols_production_labels_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."ols_products_cache"("id");



ALTER TABLE ONLY "public"."ols_shipping_labels"
    ADD CONSTRAINT "ols_shipping_labels_carton_id_fkey" FOREIGN KEY ("carton_id") REFERENCES "public"."ols_cartons"("id");



ALTER TABLE ONLY "public"."ols_shipping_labels"
    ADD CONSTRAINT "ols_shipping_labels_pi_id_fkey" FOREIGN KEY ("pi_id") REFERENCES "public"."ols_finance_pi"("id");



ALTER TABLE ONLY "public"."ols_stock_units"
    ADD CONSTRAINT "ols_stock_units_production_label_id_fkey" FOREIGN KEY ("production_label_id") REFERENCES "public"."ols_production_labels"("id");



ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_queue_item_id_fkey" FOREIGN KEY ("queue_item_id") REFERENCES "public"."operational_queue_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operational_queue_assignments"
    ADD CONSTRAINT "operational_queue_assignments_queue_item_id_fkey" FOREIGN KEY ("queue_item_id") REFERENCES "public"."operational_queue_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operational_scan_records"
    ADD CONSTRAINT "operational_scan_records_queue_item_id_fkey" FOREIGN KEY ("queue_item_id") REFERENCES "public"."operational_queue_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operational_search_index"
    ADD CONSTRAINT "operational_search_index_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_events"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operational_search_index"
    ADD CONSTRAINT "operational_search_index_queue_item_id_fkey" FOREIGN KEY ("queue_item_id") REFERENCES "public"."operational_queue_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."operational_search_index"
    ADD CONSTRAINT "operational_search_index_scan_record_id_fkey" FOREIGN KEY ("scan_record_id") REFERENCES "public"."operational_scan_records"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."order_attachments"
    ADD CONSTRAINT "order_attachments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_payments"
    ADD CONSTRAINT "order_payments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."order_payments"
    ADD CONSTRAINT "order_payments_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."order_payments"
    ADD CONSTRAINT "order_payments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_payments"
    ADD CONSTRAINT "order_payments_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_logged_by_fkey" FOREIGN KEY ("logged_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_duplicate_of_order_id_fkey" FOREIGN KEY ("duplicate_of_order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_finance_verified_by_fkey" FOREIGN KEY ("finance_verified_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."org_branches"
    ADD CONSTRAINT "org_branches_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."org_companies"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."org_companies"
    ADD CONSTRAINT "org_companies_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."org_contacts"
    ADD CONSTRAINT "org_contacts_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."org_membership_branch_scopes"
    ADD CONSTRAINT "org_membership_branch_scopes_branch_id_fkey" FOREIGN KEY ("branch_id") REFERENCES "public"."org_branches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."org_membership_branch_scopes"
    ADD CONSTRAINT "org_membership_branch_scopes_membership_id_fkey" FOREIGN KEY ("membership_id") REFERENCES "public"."org_memberships"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."org_membership_roles"
    ADD CONSTRAINT "org_membership_roles_membership_id_fkey" FOREIGN KEY ("membership_id") REFERENCES "public"."org_memberships"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."org_memberships"
    ADD CONSTRAINT "org_memberships_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."org_companies"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."org_memberships"
    ADD CONSTRAINT "org_memberships_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."org_contacts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."org_memberships"
    ADD CONSTRAINT "org_memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."packing_lists"
    ADD CONSTRAINT "packing_lists_dispatch_id_fkey" FOREIGN KEY ("dispatch_id") REFERENCES "public"."dispatches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."packing_lists"
    ADD CONSTRAINT "packing_lists_order_item_id_fkey" FOREIGN KEY ("order_item_id") REFERENCES "public"."order_items"("id");



ALTER TABLE ONLY "public"."packing_lists"
    ADD CONSTRAINT "packing_lists_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."portal_access_invites"
    ADD CONSTRAINT "portal_access_invites_application_id_fkey" FOREIGN KEY ("application_id") REFERENCES "public"."b2b_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."portal_access_invites"
    ADD CONSTRAINT "portal_access_invites_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."product_aliases"
    ADD CONSTRAINT "product_aliases_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."product_bom"
    ADD CONSTRAINT "product_bom_component_product_id_fkey" FOREIGN KEY ("component_product_id") REFERENCES "public"."products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."product_bom"
    ADD CONSTRAINT "product_bom_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_media"
    ADD CONSTRAINT "product_media_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_moq_rules"
    ADD CONSTRAINT "product_moq_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_pricing_rules"
    ADD CONSTRAINT "product_pricing_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_tag_mapping"
    ADD CONSTRAINT "product_tag_mapping_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_tag_mapping"
    ADD CONSTRAINT "product_tag_mapping_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."product_tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."production_issues"
    ADD CONSTRAINT "production_issues_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."production_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."production_jobs"
    ADD CONSTRAINT "production_jobs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."production_jobs"
    ADD CONSTRAINT "production_jobs_order_item_id_fkey" FOREIGN KEY ("order_item_id") REFERENCES "public"."order_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."production_jobs"
    ADD CONSTRAINT "production_jobs_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."production_pauses"
    ADD CONSTRAINT "production_pauses_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."production_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."production_rgs_transfers"
    ADD CONSTRAINT "production_rgs_transfers_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."production_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."production_rgs_transfers"
    ADD CONSTRAINT "production_rgs_transfers_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profile_change_requests"
    ADD CONSTRAINT "profile_change_requests_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile_change_requests"
    ADD CONSTRAINT "profile_change_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."profile_change_requests"
    ADD CONSTRAINT "profile_change_requests_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permission_grants"
    ADD CONSTRAINT "role_permission_grants_permission_key_fkey" FOREIGN KEY ("permission_key") REFERENCES "public"."access_permissions"("permission_key") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permission_map"
    ADD CONSTRAINT "role_permission_map_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permission_map"
    ADD CONSTRAINT "role_permission_map_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_order_draft_audit_log"
    ADD CONSTRAINT "sales_order_draft_audit_log_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."sales_order_drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_order_draft_lines"
    ADD CONSTRAINT "sales_order_draft_lines_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."sales_order_drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_order_drafts"
    ADD CONSTRAINT "sales_order_drafts_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales_order_drafts"
    ADD CONSTRAINT "sales_order_drafts_packet_id_fkey" FOREIGN KEY ("packet_id") REFERENCES "public"."whatsapp_message_packets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_order_drafts"
    ADD CONSTRAINT "sales_order_drafts_promoted_order_id_fkey" FOREIGN KEY ("promoted_order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."stock_consumption_lineage"
    ADD CONSTRAINT "stock_consumption_lineage_reservation_id_fkey" FOREIGN KEY ("reservation_id") REFERENCES "public"."inventory_reservations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."stock_logs"
    ADD CONSTRAINT "stock_logs_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."inventory_items"("id");



ALTER TABLE ONLY "public"."storage_bucket_contracts"
    ADD CONSTRAINT "storage_bucket_contracts_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."store_requisition_items"
    ADD CONSTRAINT "store_requisition_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."store_requisition_items"
    ADD CONSTRAINT "store_requisition_items_requisition_id_fkey" FOREIGN KEY ("requisition_id") REFERENCES "public"."store_requisitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."store_requisitions"
    ADD CONSTRAINT "store_requisitions_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."suggested_orders"
    ADD CONSTRAINT "suggested_orders_matched_company_id_fkey" FOREIGN KEY ("matched_company_id") REFERENCES "public"."companies"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."suggested_orders"
    ADD CONSTRAINT "suggested_orders_promoted_order_id_fkey" FOREIGN KEY ("promoted_order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."suggested_orders"
    ADD CONSTRAINT "suggested_orders_shadow_client_id_fkey" FOREIGN KEY ("shadow_client_id") REFERENCES "public"."shadow_clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."support_tickets"
    ADD CONSTRAINT "support_tickets_assigned_employee_id_fkey" FOREIGN KEY ("assigned_employee_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."support_tickets"
    ADD CONSTRAINT "support_tickets_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."support_tickets"
    ADD CONSTRAINT "support_tickets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."user_role_map"
    ADD CONSTRAINT "user_role_map_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_role_map"
    ADD CONSTRAINT "user_role_map_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_automations"
    ADD CONSTRAINT "whatsapp_automations_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."whatsapp_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_automations"
    ADD CONSTRAINT "whatsapp_automations_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_message_packets"
    ADD CONSTRAINT "whatsapp_message_packets_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."whatsapp_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_message_packets"
    ADD CONSTRAINT "whatsapp_message_packets_manual_merge_parent_id_fkey" FOREIGN KEY ("manual_merge_parent_id") REFERENCES "public"."whatsapp_message_packets"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."whatsapp_messages"
    ADD CONSTRAINT "whatsapp_messages_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."whatsapp_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_messages"
    ADD CONSTRAINT "whatsapp_messages_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."whatsapp_operator_decisions"
    ADD CONSTRAINT "whatsapp_operator_decisions_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."whatsapp_operator_decisions"
    ADD CONSTRAINT "whatsapp_operator_decisions_source_message_id_fkey" FOREIGN KEY ("source_message_id") REFERENCES "public"."whatsapp_inbound_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_operator_decisions"
    ADD CONSTRAINT "whatsapp_operator_decisions_whatsapp_sales_order_draft_id_fkey" FOREIGN KEY ("whatsapp_sales_order_draft_id") REFERENCES "public"."whatsapp_sales_order_drafts"("id");



ALTER TABLE ONLY "public"."whatsapp_override_log"
    ADD CONSTRAINT "whatsapp_override_log_operator_id_fkey" FOREIGN KEY ("operator_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."whatsapp_override_log"
    ADD CONSTRAINT "whatsapp_override_log_packet_id_fkey" FOREIGN KEY ("packet_id") REFERENCES "public"."whatsapp_message_packets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_sales_order_drafts"
    ADD CONSTRAINT "whatsapp_sales_order_drafts_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."whatsapp_sales_order_drafts"
    ADD CONSTRAINT "whatsapp_sales_order_drafts_resolved_product_id_fkey" FOREIGN KEY ("resolved_product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."whatsapp_sales_order_drafts"
    ADD CONSTRAINT "whatsapp_sales_order_drafts_source_message_id_fkey" FOREIGN KEY ("source_message_id") REFERENCES "public"."whatsapp_inbound_messages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."whatsapp_stitched_packets"
    ADD CONSTRAINT "whatsapp_stitched_packets_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."whatsapp_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."whatsapp_stitched_packets"
    ADD CONSTRAINT "whatsapp_stitched_packets_manual_merge_parent_id_fkey" FOREIGN KEY ("manual_merge_parent_id") REFERENCES "public"."whatsapp_stitched_packets"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."whatsapp_suggestions_log"
    ADD CONSTRAINT "whatsapp_suggestions_log_packet_id_fkey" FOREIGN KEY ("packet_id") REFERENCES "public"."whatsapp_message_packets"("id") ON DELETE CASCADE;



CREATE POLICY "ANON_CAN_SUBMIT_APPLICATION" ON "public"."b2b_applications" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "Admin All Access Dispatches" ON "public"."dispatches" USING ((( SELECT "users"."role"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admin All Access Packing" ON "public"."packing_lists" USING ((( SELECT "users"."role"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admin full access" ON "public"."profiles" USING ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("lower"("users"."role") = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admin full access to mapping" ON "public"."product_tag_mapping" USING ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("users"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admin full access to tags" ON "public"."product_tags" USING ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("users"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins can insert notifications" ON "public"."notification_outbox" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("users"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins can manage outbox" ON "public"."notification_outbox" TO "authenticated" USING ((("auth"."jwt"() ->> 'role'::"text") = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins can map roles" ON "public"."user_role_map" USING ("public"."is_admin"());



CREATE POLICY "Admins can read audit_logs" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins can update inward_material_advice" ON "public"."inward_material_advice" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins can update users" ON "public"."users" FOR UPDATE USING (("public"."is_admin"() OR ("id" = "auth"."uid"())));



CREATE POLICY "Admins can view all users" ON "public"."users" FOR SELECT USING (("public"."is_admin"() OR ("id" = "auth"."uid"())));



CREATE POLICY "Admins can view and edit all order history" ON "public"."order_status_history" USING ((( SELECT "users"."role"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())
 LIMIT 1) = ANY (ARRAY['super_admin'::"text", 'admin'::"text"])));



CREATE POLICY "Admins can view and edit all orders" ON "public"."orders" USING ((( SELECT "users"."role"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())
 LIMIT 1) = ANY (ARRAY['super_admin'::"text", 'admin'::"text"])));



CREATE POLICY "Admins can view applications" ON "public"."b2b_applications" FOR SELECT USING ((( SELECT "profiles"."role"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"())) = 'admin'::"text"));



CREATE POLICY "Admins manage app_settings" ON "public"."app_settings" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage archive_logs" ON "public"."archive_logs" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage commission_payouts" ON "public"."commission_payouts" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text", 'finance_head'::"text"])));



CREATE POLICY "Admins manage companies" ON "public"."companies" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage credit_requests" ON "public"."credit_requests" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage crm_tasks" ON "public"."crm_tasks" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'FINANCE_HEAD'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'FINANCE_HEAD'::"text"])));



CREATE POLICY "Admins manage dead letters" ON "public"."dead_letter_entries" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage employee_performance_logs" ON "public"."employee_performance_logs" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'FINANCE_HEAD'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'FINANCE_HEAD'::"text"])));



CREATE POLICY "Admins manage exchange_rates" ON "public"."exchange_rates" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage factory_holidays" ON "public"."factory_holidays" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage invoices" ON "public"."invoices" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage moq_rules" ON "public"."moq_rules" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage notification_events" ON "public"."notification_events" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage notifications" ON "public"."notifications" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage payments" ON "public"."order_payments" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage permissions" ON "public"."permissions" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage portal_access_invites" ON "public"."portal_access_invites" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage pricing_slabs" ON "public"."pricing_slabs" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage product_aliases" ON "public"."product_aliases" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"])));



CREATE POLICY "Admins manage product_moq_rules" ON "public"."product_moq_rules" USING ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("lower"("users"."role") = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage product_pricing_rules" ON "public"."product_pricing_rules" USING ((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("lower"("users"."role") = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage product_tag_mapping" ON "public"."product_tag_mapping" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage product_tags" ON "public"."product_tags" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage realtime contracts" ON "public"."realtime_subscription_contracts" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage retry policies" ON "public"."retry_policies" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage role_permission_map" ON "public"."role_permission_map" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage roles" ON "public"."roles" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage starter packs" ON "public"."starter_packs" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])));



CREATE POLICY "Admins manage system_alerts" ON "public"."system_alerts" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage system_settings" ON "public"."system_settings" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage user_role_map" ON "public"."user_role_map" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "Admins manage whatsapp_config" ON "public"."whatsapp_config" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"])));



CREATE POLICY "Allow authenticated full access on dispatches" ON "public"."dispatches" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated full access on inventory_adjustments" ON "public"."inventory_adjustments" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated full access on inventory_items" ON "public"."inventory_items" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated full access on invoices" ON "public"."invoices" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated full access on stock_logs" ON "public"."stock_logs" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated full access on user_favorites" ON "public"."user_favorites" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Anyone authenticated can read system_alerts" ON "public"."system_alerts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone can apply" ON "public"."b2b_applications" FOR INSERT WITH CHECK (true);



CREATE POLICY "Applicants insert own application" ON "public"."b2b_applications" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) OR ("user_id" IS NULL)));



CREATE POLICY "Applicants read own application" ON "public"."b2b_applications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Authenticated can insert audit_logs" ON "public"."audit_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert credit_requests" ON "public"."credit_requests" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert daily_production_logs" ON "public"."daily_production_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert freight_ledger" ON "public"."freight_ledger" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert inward_material_advice" ON "public"."inward_material_advice" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert inward_material_items" ON "public"."inward_material_items" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert order_attachments" ON "public"."order_attachments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can insert order_returns" ON "public"."order_returns" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated can read app_settings" ON "public"."app_settings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read credit_requests" ON "public"."credit_requests" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read daily_production_logs" ON "public"."daily_production_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read exchange_rates" ON "public"."exchange_rates" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read freight_ledger" ON "public"."freight_ledger" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read inward_material_items" ON "public"."inward_material_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read moq_rules" ON "public"."moq_rules" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read notification_events" ON "public"."notification_events" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read order_attachments" ON "public"."order_attachments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read order_returns" ON "public"."order_returns" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read permissions" ON "public"."permissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read pricing_slabs" ON "public"."pricing_slabs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read product_aliases" ON "public"."product_aliases" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read product_tag_mapping" ON "public"."product_tag_mapping" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read product_tags" ON "public"."product_tags" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read role_permission_map" ON "public"."role_permission_map" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read roles" ON "public"."roles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read system_settings" ON "public"."system_settings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read user_role_map" ON "public"."user_role_map" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can update inward_material_advice_status" ON "public"."inward_material_advice" FOR UPDATE TO "authenticated" USING (true);



CREATE POLICY "Authenticated full access store_requisition_items" ON "public"."store_requisition_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated full access store_requisitions" ON "public"."store_requisitions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated insert archive_logs" ON "public"."archive_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated read active starter packs" ON "public"."starter_packs" FOR SELECT TO "authenticated" USING ((("is_active" = true) OR "public"."is_internal_staff"("auth"."uid"())));



CREATE POLICY "Authenticated read commission_payouts" ON "public"."commission_payouts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read employee_performance_logs" ON "public"."employee_performance_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read invoices" ON "public"."invoices" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read product_bom" ON "public"."product_bom" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read product_moq_rules" ON "public"."product_moq_rules" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read product_pricing_rules" ON "public"."product_pricing_rules" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read whatsapp_config" ON "public"."whatsapp_config" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can view active announcements" ON "public"."premium_announcements" FOR SELECT TO "authenticated" USING ((("is_active" = true) AND ("start_date" <= "now"()) AND (("end_date" IS NULL) OR ("end_date" >= "now"()))));



CREATE POLICY "Authenticated write media" ON "public"."product_media" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Buyers attach payment receipt metadata" ON "public"."orders" FOR UPDATE TO "authenticated" USING (((NOT COALESCE("public"."is_internal_staff"("auth"."uid"()), false)) AND (NOT ("company_id" IS DISTINCT FROM "public"."auth_buyer_company_id"())) AND ("status" = ANY (ARRAY['submitted'::"text", 'approved'::"text"])) AND ("payment_status" = 'awaiting_receipt'::"text"))) WITH CHECK (((NOT ("company_id" IS DISTINCT FROM "public"."auth_buyer_company_id"())) AND ("status" = ANY (ARRAY['submitted'::"text", 'approved'::"text"])) AND ("payment_status" = 'under_review'::"text")));



CREATE POLICY "Buyers can view their own company orders" ON "public"."orders" FOR SELECT USING (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers can view their own order history" ON "public"."order_status_history" FOR SELECT USING (("order_id" IN ( SELECT "orders"."id"
   FROM "public"."orders"
  WHERE ("orders"."company_id" = ( SELECT "users"."company_id"
           FROM "public"."users"
          WHERE ("users"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "Buyers delete own order_items" ON "public"."order_items" FOR DELETE TO "authenticated" USING (("order_id" IN ( SELECT "o"."id"
   FROM "public"."orders" "o"
  WHERE ("o"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "Buyers insert own company change requests" ON "public"."profile_change_requests" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)) AND ("requested_by" = "auth"."uid"())));



CREATE POLICY "Buyers insert own company orders" ON "public"."orders" FOR INSERT WITH CHECK ((("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)) OR "public"."is_internal_staff"("auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))));



CREATE POLICY "Buyers insert own company payments" ON "public"."order_payments" FOR INSERT TO "authenticated" WITH CHECK (((NOT ("created_by" IS DISTINCT FROM "auth"."uid"())) AND (NOT ("company_id" IS DISTINCT FROM "public"."auth_buyer_company_id"())) AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_payments"."order_id") AND (NOT ("o"."company_id" IS DISTINCT FROM "o"."company_id")))))));



CREATE POLICY "Buyers insert own order_items" ON "public"."order_items" FOR INSERT WITH CHECK ((("order_id" IN ( SELECT "o"."id"
   FROM ("public"."orders" "o"
     JOIN "public"."users" "u" ON (("u"."id" = "auth"."uid"())))
  WHERE ("o"."company_id" = "u"."company_id"))) OR "public"."is_internal_staff"("auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))));



CREATE POLICY "Buyers insert own orders" ON "public"."orders" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" IS NOT NULL) AND ("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1))));



CREATE POLICY "Buyers raise own company disputes" ON "public"."ledger_disputes" FOR INSERT TO "authenticated" WITH CHECK (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers read factory_inventory" ON "public"."factory_inventory" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Buyers read own companies" ON "public"."companies" FOR SELECT TO "authenticated" USING (("id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers read own company change requests" ON "public"."profile_change_requests" FOR SELECT TO "authenticated" USING ((("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)) OR "public"."is_internal_staff"("auth"."uid"())));



CREATE POLICY "Buyers read own company disputes" ON "public"."ledger_disputes" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers read own company ledgers" ON "public"."bi_monthly_ledgers" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers read own company payments" ON "public"."order_payments" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers read own order_items" ON "public"."order_items" FOR SELECT TO "authenticated" USING (("order_id" IN ( SELECT "o"."id"
   FROM "public"."orders" "o"
  WHERE ("o"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "Buyers read own orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers revoke failed receipt ledger sync" ON "public"."orders" FOR UPDATE TO "authenticated" USING (((NOT COALESCE("public"."is_internal_staff"("auth"."uid"()), false)) AND (NOT ("company_id" IS DISTINCT FROM "public"."auth_buyer_company_id"())) AND ("status" = ANY (ARRAY['submitted'::"text", 'approved'::"text"])) AND ("payment_status" = 'under_review'::"text"))) WITH CHECK (((NOT ("company_id" IS DISTINCT FROM "public"."auth_buyer_company_id"())) AND ("status" = ANY (ARRAY['submitted'::"text", 'approved'::"text"])) AND ("payment_status" = 'awaiting_receipt'::"text") AND ("payment_receipt_url" IS NULL)));



CREATE POLICY "Buyers see own company, admins see all" ON "public"."companies" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("users"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text", 'ADMIN'::"text", 'SUPER_ADMIN'::"text", 'finance_head'::"text", 'finance_exec'::"text", 'operations_manager'::"text", 'dispatch_head'::"text", 'sales_executive'::"text"]))))) OR ("id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"())
 LIMIT 1)) OR ("id" = ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"())
 LIMIT 1))));



CREATE POLICY "Buyers update own draft orders" ON "public"."orders" FOR UPDATE TO "authenticated" USING ((("status" = 'draft'::"text") AND ("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)))) WITH CHECK (("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)));



CREATE POLICY "Buyers update own order_items" ON "public"."order_items" FOR UPDATE TO "authenticated" USING (("order_id" IN ( SELECT "o"."id"
   FROM "public"."orders" "o"
  WHERE ("o"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1))))) WITH CHECK (("order_id" IN ( SELECT "o"."id"
   FROM "public"."orders" "o"
  WHERE ("o"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "Companies view own rescue events" ON "public"."credit_rescue_events" FOR SELECT USING (("company_id" IN ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Enable read access for authenticated users" ON "public"."notification_outbox" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Individual user access" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Internal staff can insert production_jobs" ON "public"."production_jobs" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Internal staff can update production_jobs" ON "public"."production_jobs" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Internal staff can view all orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Internal staff can view auth logs" ON "public"."auth_logs" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Internal staff can view production_jobs" ON "public"."production_jobs" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Internal staff read realtime contracts" ON "public"."realtime_subscription_contracts" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "OASIS_ADMIN_FULL_CONTROL" ON "public"."products" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "OASIS_ADMIN_FULL_CONTROL" ON "public"."users" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "OASIS_AUTHENTICATED_FULL_ACCESS" ON "public"."categories" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "OASIS_AUTHENTICATED_FULL_ACCESS" ON "public"."product_variants" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "OASIS_AUTH_INSERT_BYPASS" ON "public"."companies" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Ops manage shadow_clients" ON "public"."shadow_clients" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OPERATIONS_MANAGER'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OPERATIONS_MANAGER'::"text"])));



CREATE POLICY "Ops manage suggested_orders" ON "public"."suggested_orders" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OPERATIONS_MANAGER'::"text"]))) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OPERATIONS_MANAGER'::"text"])));



CREATE POLICY "Ops read suggested_orders" ON "public"."suggested_orders" FOR SELECT TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OPERATIONS_MANAGER'::"text"])));



CREATE POLICY "Public mapping readable by all" ON "public"."product_tag_mapping" FOR SELECT USING (true);



CREATE POLICY "Public read media" ON "public"."product_media" FOR SELECT USING (true);



CREATE POLICY "Public tags readable by all" ON "public"."product_tags" FOR SELECT USING (true);



CREATE POLICY "Sales execs insert crm_tasks" ON "public"."crm_tasks" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_account_manager"("auth"."uid"(), "company_id") OR ("sales_exec_id" = "auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"]))));



CREATE POLICY "Sales execs insert own client interactions" ON "public"."client_interactions" FOR INSERT TO "authenticated" WITH CHECK ((("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])) OR "public"."is_account_manager"("auth"."uid"(), "company_id")));



CREATE POLICY "Sales execs read own crm_tasks" ON "public"."crm_tasks" FOR SELECT TO "authenticated" USING (("public"."is_account_manager"("auth"."uid"(), "company_id") OR ("sales_exec_id" = "auth"."uid"())));



CREATE POLICY "Sales execs see own client interactions" ON "public"."client_interactions" FOR SELECT TO "authenticated" USING ((("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text", 'finance_head'::"text"])) OR "public"."is_account_manager"("auth"."uid"(), "company_id")));



CREATE POLICY "Sales execs update own crm_tasks" ON "public"."crm_tasks" FOR UPDATE TO "authenticated" USING ((("sales_exec_id" = "auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"])))) WITH CHECK ((("sales_exec_id" = "auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['ADMIN'::"text", 'SUPER_ADMIN'::"text"]))));



CREATE POLICY "Sales executives read assigned companies" ON "public"."companies" FOR SELECT TO "authenticated" USING ((("upper"("public"."get_user_role"("auth"."uid"())) = 'SALES_EXECUTIVE'::"text") AND "public"."is_account_manager"("auth"."uid"(), "id")));



CREATE POLICY "Sales executives read assigned order_items" ON "public"."order_items" FOR SELECT TO "authenticated" USING ((("upper"("public"."get_user_role"("auth"."uid"())) = 'SALES_EXECUTIVE'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_items"."order_id") AND "public"."is_account_manager"("auth"."uid"(), "o"."company_id"))))));



CREATE POLICY "Sales executives read assigned orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ((("upper"("public"."get_user_role"("auth"."uid"())) = 'SALES_EXECUTIVE'::"text") AND "public"."is_account_manager"("auth"."uid"(), "company_id")));



CREATE POLICY "Scoped read inward_material_advice" ON "public"."inward_material_advice" FOR SELECT TO "authenticated" USING ((("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text", 'finance_head'::"text", 'dispatch_head'::"text"])) OR "public"."is_account_manager"("auth"."uid"(), "company_id")));



CREATE POLICY "Service role full access debug_webhooks" ON "public"."debug_webhooks" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access product_aliases" ON "public"."product_aliases" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access shadow_clients" ON "public"."shadow_clients" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access suggested_orders" ON "public"."suggested_orders" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access whatsapp_buffer" ON "public"."whatsapp_buffer" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Staff can delete all orders" ON "public"."orders" FOR DELETE TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff can insert all orders" ON "public"."orders" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff can manage announcements" ON "public"."premium_announcements" TO "authenticated" USING ("public"."is_staff_role"("public"."get_user_role"("auth"."uid"()))) WITH CHECK ("public"."is_staff_role"("public"."get_user_role"("auth"."uid"())));



CREATE POLICY "Staff can manage production_issues" ON "public"."production_issues" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff can manage production_pauses" ON "public"."production_pauses" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff can manage rgs_transfers" ON "public"."production_rgs_transfers" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff can update all orders" ON "public"."orders" FOR UPDATE TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text"))) WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff delete applications" ON "public"."b2b_applications" FOR DELETE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff full access bi_monthly_ledgers" ON "public"."bi_monthly_ledgers" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff full access dispatch_cartons" ON "public"."dispatch_cartons" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff full access factory_inventory" ON "public"."factory_inventory" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff full access ledger_disputes" ON "public"."ledger_disputes" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff full access order_items" ON "public"."order_items" TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text"))) WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff full access to rescue events" ON "public"."credit_rescue_events" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert debug_webhooks" ON "public"."debug_webhooks" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert inventory movements" ON "public"."inventory_movements" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert inventory reservations" ON "public"."inventory_reservations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert operational events" ON "public"."operational_events" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert operational queue assignments" ON "public"."operational_queue_assignments" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert operational queue items" ON "public"."operational_queue_items" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert operational scan records" ON "public"."operational_scan_records" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert operational search index" ON "public"."operational_search_index" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert reservation allocations" ON "public"."inventory_reservation_allocations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert stock balances" ON "public"."inventory_stock_balances" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert stock consumption lineage" ON "public"."stock_consumption_lineage" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff insert whatsapp_buffer" ON "public"."whatsapp_buffer" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff manage applications" ON "public"."b2b_applications" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff manage change requests" ON "public"."profile_change_requests" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff manage order payments" ON "public"."order_payments" TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))));



CREATE POLICY "Staff manage product_bom" ON "public"."product_bom" TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) OR ("public"."get_user_role"("auth"."uid"()) = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))));



CREATE POLICY "Staff manage profiles" ON "public"."profiles" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read all applications" ON "public"."b2b_applications" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read all companies" ON "public"."companies" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff read all orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "Staff read dead letters" ON "public"."dead_letter_entries" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read debug_webhooks" ON "public"."debug_webhooks" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read inventory movements" ON "public"."inventory_movements" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read inventory reservations" ON "public"."inventory_reservations" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read operational events" ON "public"."operational_events" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read operational queue assignments" ON "public"."operational_queue_assignments" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read operational queue items" ON "public"."operational_queue_items" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read operational scan records" ON "public"."operational_scan_records" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read operational search index" ON "public"."operational_search_index" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read reservation allocations" ON "public"."inventory_reservation_allocations" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read retry policies" ON "public"."retry_policies" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read shadow_clients" ON "public"."shadow_clients" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read stock balances" ON "public"."inventory_stock_balances" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read stock consumption lineage" ON "public"."stock_consumption_lineage" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read storage bucket contracts" ON "public"."storage_bucket_contracts" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff read whatsapp_buffer" ON "public"."whatsapp_buffer" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff update inventory reservations" ON "public"."inventory_reservations" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff update operational queue items" ON "public"."operational_queue_items" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff update operational search index" ON "public"."operational_search_index" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff update reservation allocations" ON "public"."inventory_reservation_allocations" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Staff update stock balances governed" ON "public"."inventory_stock_balances" FOR UPDATE TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "Super admins manage storage bucket contracts" ON "public"."storage_bucket_contracts" TO "authenticated" USING (("public"."get_user_role"("auth"."uid"()) = 'super_admin'::"text")) WITH CHECK (("public"."get_user_role"("auth"."uid"()) = 'super_admin'::"text"));



CREATE POLICY "Team insert catalogue_sync_events" ON "public"."catalogue_sync_events" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team insert catalogue_versions" ON "public"."catalogue_versions" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team insert sku_code_rules" ON "public"."sku_code_rules" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read catalogue_sync_events" ON "public"."catalogue_sync_events" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read catalogue_versions" ON "public"."catalogue_versions" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read sku_code_rules" ON "public"."sku_code_rules" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read whatsapp inbound messages" ON "public"."whatsapp_inbound_messages" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read whatsapp operator decisions" ON "public"."whatsapp_operator_decisions" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team read whatsapp sales order drafts" ON "public"."whatsapp_sales_order_drafts" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team update catalogue_versions" ON "public"."catalogue_versions" FOR UPDATE TO "authenticated" USING ("public"."is_team_member"("auth"."uid"())) WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Team update sku_code_rules" ON "public"."sku_code_rules" FOR UPDATE TO "authenticated" USING ("public"."is_team_member"("auth"."uid"())) WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "Users can delete their company addresses" ON "public"."delivery_addresses" FOR DELETE USING (("company_id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert company addresses" ON "public"."delivery_addresses" FOR INSERT WITH CHECK (("company_id" IN ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert their company addresses" ON "public"."delivery_addresses" FOR INSERT WITH CHECK (("company_id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can update their company addresses" ON "public"."delivery_addresses" FOR UPDATE USING (("company_id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can view company addresses" ON "public"."delivery_addresses" FOR SELECT USING (("company_id" IN ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Users can view company orders" ON "public"."orders" FOR SELECT USING (("company_id" IN ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Users can view their company addresses" ON "public"."delivery_addresses" FOR SELECT USING (("company_id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can view their dispatches" ON "public"."dispatches" FOR SELECT USING (("order_id" IN ( SELECT "orders"."id"
   FROM "public"."orders"
  WHERE ("orders"."company_id" = ( SELECT "users"."company_id"
           FROM "public"."users"
          WHERE ("users"."id" = "auth"."uid"()))))));



CREATE POLICY "Users can view their documents" ON "public"."documents" FOR SELECT USING (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Users can view their wallet" ON "public"."wallet_transactions" FOR SELECT USING (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = "auth"."uid"()))));



CREATE POLICY "Users insert own profile" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK (("id" = "auth"."uid"()));



CREATE POLICY "Users read own profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "Users read own profile only" ON "public"."profiles" FOR SELECT USING ((("id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND ("lower"("users"."role") = ANY (ARRAY['admin'::"text", 'super_admin'::"text", 'finance_head'::"text", 'finance_exec'::"text", 'operations_manager'::"text", 'dispatch_head'::"text", 'sales_executive'::"text", 'support_executive'::"text", 'store_incharge'::"text", 'production_manager'::"text", 'dispatch_manager'::"text", 'security_control'::"text", 'catalogue_contributor'::"text"])))))));



CREATE POLICY "Users read own role mapping" ON "public"."user_role_map" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."access_permissions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "access_permissions_manage" ON "public"."access_permissions" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid"));



CREATE POLICY "access_permissions_select" ON "public"."access_permissions" FOR SELECT TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'rbac.read'::"text", NULL::"uuid", NULL::"uuid"));



ALTER TABLE "public"."admin_manual_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."archive_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."auth_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."b2b_applications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bi_monthly_ledgers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "buyer_insert_own_order_payments" ON "public"."order_payments" FOR INSERT TO "authenticated" WITH CHECK (("order_id" IN ( SELECT "orders"."id"
   FROM "public"."orders"
  WHERE ("orders"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "buyer_read_own_order_payments" ON "public"."order_payments" FOR SELECT TO "authenticated" USING (("order_id" IN ( SELECT "orders"."id"
   FROM "public"."orders"
  WHERE ("orders"."company_id" = ( SELECT "u"."company_id"
           FROM "public"."users" "u"
          WHERE ("u"."id" = "auth"."uid"())
         LIMIT 1)))));



CREATE POLICY "buyer_update_submitted_order_receipt" ON "public"."orders" FOR UPDATE TO "authenticated" USING ((("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)) AND ("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text"])))) WITH CHECK ((("company_id" = ( SELECT "u"."company_id"
   FROM "public"."users" "u"
  WHERE ("u"."id" = "auth"."uid"())
 LIMIT 1)) AND ("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text"]))));



ALTER TABLE "public"."catalogue_ai_studio_draft_audit_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "catalogue_ai_studio_draft_audit_service_role" ON "public"."catalogue_ai_studio_draft_audit_log" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "catalogue_ai_studio_draft_audit_staff_insert" ON "public"."catalogue_ai_studio_draft_audit_log" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "catalogue_ai_studio_draft_audit_staff_select" ON "public"."catalogue_ai_studio_draft_audit_log" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



ALTER TABLE "public"."catalogue_ai_studio_drafts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "catalogue_ai_studio_drafts_service_role" ON "public"."catalogue_ai_studio_drafts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "catalogue_ai_studio_drafts_staff_insert" ON "public"."catalogue_ai_studio_drafts" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "catalogue_ai_studio_drafts_staff_select" ON "public"."catalogue_ai_studio_drafts" FOR SELECT TO "authenticated" USING ("public"."is_team_member"("auth"."uid"()));



CREATE POLICY "catalogue_ai_studio_drafts_staff_update" ON "public"."catalogue_ai_studio_drafts" FOR UPDATE TO "authenticated" USING ("public"."is_team_member"("auth"."uid"())) WITH CHECK ("public"."is_team_member"("auth"."uid"()));



ALTER TABLE "public"."catalogue_alias_drafts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "catalogue_app_alias_drafts_insert_submitter" ON "public"."catalogue_alias_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.alias.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_alias_drafts_reviewer_select" ON "public"."catalogue_alias_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_alias_drafts_select_own" ON "public"."catalogue_alias_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_approval_audit_reviewer_select" ON "public"."catalogue_approval_audit" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_bom_drafts_insert_submitter" ON "public"."catalogue_bom_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.bom.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_bom_drafts_reviewer_select" ON "public"."catalogue_bom_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_bom_drafts_select_own" ON "public"."catalogue_bom_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_media_submissions_insert_submitter" ON "public"."catalogue_media_submissions" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.media.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_media_submissions_reviewer_select" ON "public"."catalogue_media_submissions" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_media_submissions_select_own" ON "public"."catalogue_media_submissions" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_moq_drafts_insert_submitter" ON "public"."catalogue_moq_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.moq.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_moq_drafts_reviewer_select" ON "public"."catalogue_moq_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_moq_drafts_select_own" ON "public"."catalogue_moq_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_pricing_drafts_insert_submitter" ON "public"."catalogue_pricing_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.pricing.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_pricing_drafts_reviewer_select" ON "public"."catalogue_pricing_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_pricing_drafts_select_own" ON "public"."catalogue_pricing_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_product_drafts_insert_submitter" ON "public"."catalogue_product_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.products.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_product_drafts_reviewer_select" ON "public"."catalogue_product_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_product_drafts_select_own" ON "public"."catalogue_product_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



CREATE POLICY "catalogue_app_tag_drafts_insert_submitter" ON "public"."catalogue_tag_drafts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_catalogue_permission"('catalogue.tags.submit'::"text") AND ("submitted_by" = "auth"."uid"()) AND ("status" = 'pending_approval'::"text")));



CREATE POLICY "catalogue_app_tag_drafts_reviewer_select" ON "public"."catalogue_tag_drafts" FOR SELECT TO "authenticated" USING ("public"."is_catalogue_reviewer"());



CREATE POLICY "catalogue_app_tag_drafts_select_own" ON "public"."catalogue_tag_drafts" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



ALTER TABLE "public"."catalogue_approval_audit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_bom_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_media_submissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_moq_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_pricing_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_product_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_product_mappings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "catalogue_product_mappings_select_internal" ON "public"."catalogue_product_mappings" FOR SELECT TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"()));



CREATE POLICY "catalogue_product_mappings_write_internal" ON "public"."catalogue_product_mappings" TO "authenticated" USING ("public"."is_internal_staff"("auth"."uid"())) WITH CHECK ("public"."is_internal_staff"("auth"."uid"()));



ALTER TABLE "public"."catalogue_sync_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_tag_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."catalogue_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_interactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."commission_payouts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_rescue_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customer_import_batches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customer_import_batches_service_all" ON "public"."customer_import_batches" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."customer_import_company_candidates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customer_import_company_service_all" ON "public"."customer_import_company_candidates" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."customer_import_contact_candidates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customer_import_contact_service_all" ON "public"."customer_import_contact_candidates" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."customer_import_duplicate_review" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customer_import_duplicate_service_all" ON "public"."customer_import_duplicate_review" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."customer_import_raw" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customer_import_raw_service_all" ON "public"."customer_import_raw" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."daily_production_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dead_letter_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."debug_webhooks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."delivery_addresses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dispatch_cartons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dispatch_completion_evidence" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dispatch_completion_evidence_dispatch_insert" ON "public"."dispatch_completion_evidence" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) = ANY (ARRAY['DISPATCH_MANAGER'::"text", 'DISPATCH_HEAD'::"text", 'DISPATCH_INCHARGE'::"text", 'OPERATIONS_MANAGER'::"text", 'ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OWNER'::"text"]))));



CREATE POLICY "dispatch_completion_evidence_staff_select" ON "public"."dispatch_completion_evidence" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



ALTER TABLE "public"."dispatch_readiness_evidence" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dispatch_readiness_evidence_staff_insert" ON "public"."dispatch_readiness_evidence" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



CREATE POLICY "dispatch_readiness_evidence_staff_select" ON "public"."dispatch_readiness_evidence" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



ALTER TABLE "public"."dispatch_release_lineage" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dispatch_release_lineage_dispatch_insert" ON "public"."dispatch_release_lineage" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) = ANY (ARRAY['DISPATCH_MANAGER'::"text", 'DISPATCH_HEAD'::"text", 'DISPATCH_INCHARGE'::"text", 'OPERATIONS_MANAGER'::"text", 'ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OWNER'::"text"]))));



CREATE POLICY "dispatch_release_lineage_staff_select" ON "public"."dispatch_release_lineage" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



ALTER TABLE "public"."dispatches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_performance_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."exchange_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."factory_holidays" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."factory_inventory" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "finance_exec_read_all_orders" ON "public"."orders" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'finance_exec'::"text"));



CREATE POLICY "finance_exec_update_payment_fields" ON "public"."orders" FOR UPDATE USING ((("auth"."jwt"() ->> 'role'::"text") = 'finance_exec'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'finance_exec'::"text"));



ALTER TABLE "public"."finance_review_evidence" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "finance_review_evidence_finance_insert" ON "public"."finance_review_evidence" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) = ANY (ARRAY['FINANCE_HEAD'::"text", 'FINANCE_EXEC'::"text", 'ADMIN'::"text", 'SUPER_ADMIN'::"text", 'OWNER'::"text"]))));



CREATE POLICY "finance_review_evidence_staff_select" ON "public"."finance_review_evidence" FOR SELECT TO "authenticated" USING (("public"."is_internal_staff"("auth"."uid"()) AND ("upper"("public"."get_user_role"("auth"."uid"())) <> 'SALES_EXECUTIVE'::"text")));



ALTER TABLE "public"."freight_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."identity_profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "identity_profiles_manage" ON "public"."identity_profiles" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid"));



CREATE POLICY "identity_profiles_select" ON "public"."identity_profiles" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."has_app_permission"("auth"."uid"(), 'rbac.read'::"text", NULL::"uuid", NULL::"uuid")));



ALTER TABLE "public"."inventory_adjustments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_movements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_reservation_allocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_reservations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_stock_balances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inward_material_advice" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inward_material_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ledger_disputes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."moq_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ols_auth_read" ON "public"."ols_audit_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_carton_contents" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_cartons" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_departments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_dispatch_document_bundles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_dpl_cartons" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_dpl_documents" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_finance_pi" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_finance_pi_cartons" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_finance_pi_lines" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_gate_scans" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_inventory_movements" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_label_templates" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_manual_override_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_orders_cache" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_permissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_print_jobs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_print_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_printer_settings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_printers" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_production_batches" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_production_labels" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_products_cache" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_profiles_light" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_reprint_requests" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_scan_history" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_settings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_shipping_labels" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_read" ON "public"."ols_stock_units" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_audit_logs" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_carton_contents" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_cartons" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_departments" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_dispatch_document_bundles" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_dpl_cartons" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_dpl_documents" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_finance_pi" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_finance_pi_cartons" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_finance_pi_lines" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_gate_scans" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_inventory_movements" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_label_templates" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_manual_override_logs" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_orders_cache" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_permissions" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_print_jobs" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_print_logs" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_printer_settings" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_printers" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_production_batches" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_production_labels" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_products_cache" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_profiles_light" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_reprint_requests" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_scan_history" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_settings" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_shipping_labels" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_update" ON "public"."ols_stock_units" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_audit_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_carton_contents" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_cartons" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_departments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_dispatch_document_bundles" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_dpl_cartons" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_dpl_documents" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_finance_pi" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_finance_pi_cartons" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_finance_pi_lines" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_gate_scans" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_inventory_movements" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_label_templates" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_manual_override_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_orders_cache" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_permissions" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_print_jobs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_print_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_printer_settings" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_printers" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_production_batches" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_production_labels" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_products_cache" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_profiles_light" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_reprint_requests" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_scan_history" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_settings" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_shipping_labels" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "ols_auth_write" ON "public"."ols_stock_units" FOR INSERT TO "authenticated" WITH CHECK (true);



ALTER TABLE "public"."ols_carton_contents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_cartons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_departments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_dispatch_document_bundles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_dpl_cartons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_dpl_documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_finance_pi" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_finance_pi_cartons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_finance_pi_lines" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_gate_scans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_inventory_movements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_label_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_manual_override_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_orders_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_print_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_print_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_printer_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_printers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_production_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_production_labels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_products_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_profiles_light" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_reprint_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_scan_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_shipping_labels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ols_stock_units" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operational_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operational_queue_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operational_queue_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operational_scan_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operational_search_index" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "operations_view_in_production_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ((("upper"("public"."get_user_role"("auth"."uid"())) = ANY (ARRAY['SUPER_ADMIN'::"text", 'ADMIN'::"text", 'OWNER'::"text", 'OPERATIONS_MANAGER'::"text", 'OPERATIONS_EXEC'::"text", 'PRODUCTION_MANAGER'::"text", 'ASSEMBLY_MANAGER'::"text", 'PACKING_SUPERVISOR'::"text", 'DISPATCH_HEAD'::"text", 'DISPATCH_MANAGER'::"text"])) AND ("status" = ANY (ARRAY['in_production'::"text", 'dispatched'::"text", 'delivered'::"text"]))));



CREATE POLICY "ops_manager_read_cleared_orders" ON "public"."orders" FOR SELECT USING (((("auth"."jwt"() ->> 'role'::"text") = 'operations_manager'::"text") AND (("payment_status" = ANY (ARRAY['verified_advance'::"text", 'on_credit'::"text", 'paid'::"text", 'advance_paid'::"text"])) OR ("status" = ANY (ARRAY['in_production'::"text", 'dispatched'::"text", 'fulfilled'::"text", 'partially_fulfilled'::"text"])))));



ALTER TABLE "public"."order_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_returns" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_status_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."org_branches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_branches_manage" ON "public"."org_branches" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "company_id", "id")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "company_id", "id"));



CREATE POLICY "org_branches_select" ON "public"."org_branches" FOR SELECT TO "authenticated" USING (("public"."has_active_company_membership"("auth"."uid"(), "company_id") OR "public"."has_app_permission"("auth"."uid"(), 'org.read'::"text", "company_id", "id")));



ALTER TABLE "public"."org_companies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_companies_manage" ON "public"."org_companies" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "id", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "id", NULL::"uuid"));



CREATE POLICY "org_companies_select" ON "public"."org_companies" FOR SELECT TO "authenticated" USING (("public"."has_active_company_membership"("auth"."uid"(), "id") OR "public"."has_app_permission"("auth"."uid"(), 'org.read'::"text", "id", NULL::"uuid")));



ALTER TABLE "public"."org_contacts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_contacts_manage" ON "public"."org_contacts" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", NULL::"uuid", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", NULL::"uuid", NULL::"uuid"));



CREATE POLICY "org_contacts_select" ON "public"."org_contacts" FOR SELECT TO "authenticated" USING ((("auth_user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."contact_id" = "org_contacts"."id") AND "public"."has_active_company_membership"("auth"."uid"(), "m"."company_id")))) OR "public"."has_app_permission"("auth"."uid"(), 'org.read'::"text", NULL::"uuid", NULL::"uuid")));



ALTER TABLE "public"."org_membership_branch_scopes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_membership_branch_scopes_manage" ON "public"."org_membership_branch_scopes" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_branch_scopes"."membership_id") AND "public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "m"."company_id", "org_membership_branch_scopes"."branch_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_branch_scopes"."membership_id") AND "public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "m"."company_id", "org_membership_branch_scopes"."branch_id")))));



CREATE POLICY "org_membership_branch_scopes_select" ON "public"."org_membership_branch_scopes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_branch_scopes"."membership_id") AND (("m"."user_id" = "auth"."uid"()) OR "public"."has_active_company_membership"("auth"."uid"(), "m"."company_id") OR "public"."has_app_permission"("auth"."uid"(), 'org.read'::"text", "m"."company_id", "org_membership_branch_scopes"."branch_id"))))));



ALTER TABLE "public"."org_membership_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_membership_roles_manage" ON "public"."org_membership_roles" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_roles"."membership_id") AND "public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", "m"."company_id", NULL::"uuid"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_roles"."membership_id") AND "public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", "m"."company_id", NULL::"uuid")))));



CREATE POLICY "org_membership_roles_select" ON "public"."org_membership_roles" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."org_memberships" "m"
  WHERE (("m"."id" = "org_membership_roles"."membership_id") AND (("m"."user_id" = "auth"."uid"()) OR "public"."has_active_company_membership"("auth"."uid"(), "m"."company_id") OR "public"."has_app_permission"("auth"."uid"(), 'rbac.read'::"text", "m"."company_id", NULL::"uuid"))))));



ALTER TABLE "public"."org_memberships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "org_memberships_manage" ON "public"."org_memberships" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "company_id", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'org.manage'::"text", "company_id", NULL::"uuid"));



CREATE POLICY "org_memberships_select" ON "public"."org_memberships" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."has_active_company_membership"("auth"."uid"(), "company_id") OR "public"."has_app_permission"("auth"."uid"(), 'org.read'::"text", "company_id", NULL::"uuid")));



CREATE POLICY "override_log_insert" ON "public"."whatsapp_override_log" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'director'::"text"]))))));



CREATE POLICY "override_log_view" ON "public"."whatsapp_override_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'finance'::"text", 'director'::"text"]))))));



ALTER TABLE "public"."packing_lists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."portal_access_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."premium_announcements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pricing_slabs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_aliases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_bom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_media" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_moq_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_pricing_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_tag_mapping" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_variants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."production_issues" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."production_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."production_pauses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."production_rgs_transfers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profile_change_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."realtime_subscription_contracts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."retry_policies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."role_permission_grants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "role_permission_grants_manage" ON "public"."role_permission_grants" TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid")) WITH CHECK ("public"."has_app_permission"("auth"."uid"(), 'rbac.manage'::"text", NULL::"uuid", NULL::"uuid"));



CREATE POLICY "role_permission_grants_select" ON "public"."role_permission_grants" FOR SELECT TO "authenticated" USING ("public"."has_app_permission"("auth"."uid"(), 'rbac.read'::"text", NULL::"uuid", NULL::"uuid"));



ALTER TABLE "public"."role_permission_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_exec_read_own_customers" ON "public"."orders" FOR SELECT USING (((("auth"."jwt"() ->> 'role'::"text") = 'sales_exec'::"text") AND ("company_id" IN ( SELECT "companies"."id"
   FROM "public"."companies"
  WHERE ("companies"."account_manager_id" = "auth"."uid"())))));



CREATE POLICY "sales_order_draft_audit_inbox_reader_insert" ON "public"."sales_order_draft_audit_log" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



CREATE POLICY "sales_order_draft_audit_inbox_reader_select" ON "public"."sales_order_draft_audit_log" FOR SELECT TO "authenticated" USING ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



ALTER TABLE "public"."sales_order_draft_audit_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_order_draft_audit_service_role" ON "public"."sales_order_draft_audit_log" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."sales_order_draft_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_order_draft_lines_inbox_reader_insert" ON "public"."sales_order_draft_lines" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_whatsapp_inbox_reader"("auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."sales_order_drafts" "d"
  WHERE ("d"."id" = "sales_order_draft_lines"."draft_id")))));



CREATE POLICY "sales_order_draft_lines_inbox_reader_select" ON "public"."sales_order_draft_lines" FOR SELECT TO "authenticated" USING (("public"."is_whatsapp_inbox_reader"("auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."sales_order_drafts" "d"
  WHERE ("d"."id" = "sales_order_draft_lines"."draft_id")))));



CREATE POLICY "sales_order_draft_lines_inbox_reader_update" ON "public"."sales_order_draft_lines" FOR UPDATE TO "authenticated" USING (("public"."is_whatsapp_inbox_reader"("auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."sales_order_drafts" "d"
  WHERE ("d"."id" = "sales_order_draft_lines"."draft_id"))))) WITH CHECK (("public"."is_whatsapp_inbox_reader"("auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."sales_order_drafts" "d"
  WHERE ("d"."id" = "sales_order_draft_lines"."draft_id")))));



CREATE POLICY "sales_order_draft_lines_service_role" ON "public"."sales_order_draft_lines" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."sales_order_drafts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_order_drafts_inbox_reader_insert" ON "public"."sales_order_drafts" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



CREATE POLICY "sales_order_drafts_inbox_reader_select" ON "public"."sales_order_drafts" FOR SELECT TO "authenticated" USING ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



CREATE POLICY "sales_order_drafts_inbox_reader_update" ON "public"."sales_order_drafts" FOR UPDATE TO "authenticated" USING ("public"."is_whatsapp_inbox_reader"("auth"."uid"())) WITH CHECK ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



CREATE POLICY "sales_order_drafts_service_role" ON "public"."sales_order_drafts" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."shadow_clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sku_code_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."starter_packs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stock_consumption_lineage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stock_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."storage_bucket_contracts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."store_requisition_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."store_requisitions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suggested_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "suggestions_log_view" ON "public"."whatsapp_suggestions_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'finance'::"text", 'director'::"text"]))))));



ALTER TABLE "public"."support_tickets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "support_tickets_admin_all" ON "public"."support_tickets" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])) AND (COALESCE("u"."is_active", true) IS TRUE) AND ("u"."deleted_at" IS NULL))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"])) AND (COALESCE("u"."is_active", true) IS TRUE) AND ("u"."deleted_at" IS NULL)))));



CREATE POLICY "support_tickets_customer_insert" ON "public"."support_tickets" FOR INSERT TO "authenticated" WITH CHECK ((("created_by" = "auth"."uid"()) AND ("user_id" = "auth"."uid"()) AND ("company_id" IN ( SELECT "p"."company_id"
   FROM ("public"."profiles" "p"
     JOIN "public"."companies" "c" ON (("c"."id" = "p"."company_id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."is_approved" IS TRUE) AND ("lower"(COALESCE("p"."status", ''::"text")) = 'approved'::"text") AND ("lower"(COALESCE("c"."status", ''::"text")) = ANY (ARRAY['active'::"text", 'approved'::"text"])) AND (COALESCE("c"."is_frozen", false) IS FALSE))
UNION
 SELECT "u"."company_id"
   FROM ("public"."users" "u"
     JOIN "public"."companies" "c" ON (("c"."id" = "u"."company_id")))
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['customer_user'::"text", 'customer_admin'::"text", 'buyer'::"text", 'b2b_customer'::"text"])) AND (COALESCE("u"."is_active", true) IS TRUE) AND ("u"."deleted_at" IS NULL) AND ("lower"(COALESCE("c"."status", ''::"text")) = ANY (ARRAY['active'::"text", 'approved'::"text"])) AND (COALESCE("c"."is_frozen", false) IS FALSE))))));



CREATE POLICY "support_tickets_customer_select" ON "public"."support_tickets" FOR SELECT TO "authenticated" USING (("company_id" IN ( SELECT "p"."company_id"
   FROM ("public"."profiles" "p"
     JOIN "public"."companies" "c" ON (("c"."id" = "p"."company_id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."is_approved" IS TRUE) AND ("lower"(COALESCE("p"."status", ''::"text")) = 'approved'::"text") AND ("lower"(COALESCE("c"."status", ''::"text")) = ANY (ARRAY['active'::"text", 'approved'::"text"])) AND (COALESCE("c"."is_frozen", false) IS FALSE))
UNION
 SELECT "u"."company_id"
   FROM ("public"."users" "u"
     JOIN "public"."companies" "c" ON (("c"."id" = "u"."company_id")))
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['customer_user'::"text", 'customer_admin'::"text", 'buyer'::"text", 'b2b_customer'::"text"])) AND (COALESCE("u"."is_active", true) IS TRUE) AND ("u"."deleted_at" IS NULL) AND ("lower"(COALESCE("c"."status", ''::"text")) = ANY (ARRAY['active'::"text", 'approved'::"text"])) AND (COALESCE("c"."is_frozen", false) IS FALSE)))));



ALTER TABLE "public"."system_alerts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tickets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_role_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wallet_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_automations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_buffer" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_contacts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "whatsapp_contacts_inbox_reader_select" ON "public"."whatsapp_contacts" FOR SELECT TO "authenticated" USING ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



ALTER TABLE "public"."whatsapp_inbound_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_message_packets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "whatsapp_messages_finance_ops" ON "public"."whatsapp_messages" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "whatsapp_messages"."order_id") AND ("upper"("public"."get_user_role"("auth"."uid"())) = ANY (ARRAY['FINANCE_HEAD'::"text", 'FINANCE_EXEC'::"text", 'OPERATIONS_MANAGER'::"text", 'OPERATIONS_EXEC'::"text", 'PRODUCTION_MANAGER'::"text", 'ASSEMBLY_MANAGER'::"text", 'DISPATCH_HEAD'::"text", 'DISPATCH_MANAGER'::"text", 'SUPER_ADMIN'::"text", 'ADMIN'::"text", 'OWNER'::"text"]))))));



CREATE POLICY "whatsapp_messages_inbox_thread_select" ON "public"."whatsapp_messages" FOR SELECT TO "authenticated" USING ((("packet_id" IS NOT NULL) AND "public"."is_whatsapp_inbox_reader"("auth"."uid"())));



ALTER TABLE "public"."whatsapp_operator_decisions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_override_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "whatsapp_packets_inbox_reader_select" ON "public"."whatsapp_message_packets" FOR SELECT TO "authenticated" USING ("public"."is_whatsapp_inbox_reader"("auth"."uid"()));



CREATE POLICY "whatsapp_packets_insert" ON "public"."whatsapp_message_packets" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'director'::"text"]))))));



CREATE POLICY "whatsapp_packets_no_delete" ON "public"."whatsapp_message_packets" FOR DELETE USING (false);



CREATE POLICY "whatsapp_packets_no_delete" ON "public"."whatsapp_stitched_packets" FOR DELETE USING (false);



CREATE POLICY "whatsapp_packets_update" ON "public"."whatsapp_message_packets" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'director'::"text"]))))));



CREATE POLICY "whatsapp_packets_update" ON "public"."whatsapp_stitched_packets" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'director'::"text"]))))));



CREATE POLICY "whatsapp_packets_view" ON "public"."whatsapp_message_packets" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'finance'::"text", 'director'::"text"]))))));



CREATE POLICY "whatsapp_packets_view" ON "public"."whatsapp_stitched_packets" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_map" "urm"
     JOIN "public"."roles" "r" ON (("r"."id" = "urm"."role_id")))
  WHERE (("urm"."user_id" = "auth"."uid"()) AND ("r"."role_key" = ANY (ARRAY['operations'::"text", 'finance'::"text", 'director'::"text"]))))));



ALTER TABLE "public"."whatsapp_sales_order_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_stitched_packets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_studio_inbox_bridge_state" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."whatsapp_suggestions_log" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."whatsapp_inbound_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."whatsapp_operator_decisions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."whatsapp_sales_order_drafts";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";


















































































































































































































GRANT ALL ON FUNCTION "public"."activate_company_on_application_approval"() TO "anon";
GRANT ALL ON FUNCTION "public"."activate_company_on_application_approval"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."activate_company_on_application_approval"() TO "service_role";



GRANT ALL ON FUNCTION "public"."app_verse_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."app_verse_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."app_verse_set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."append_operational_event_v1"("p_event_type" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_title" "text", "p_source_application" "text", "p_correlation_id" "text", "p_metadata" "jsonb", "p_order_id" "uuid", "p_customer_id" "uuid", "p_queue_item_id" "uuid", "p_actor_id" "uuid", "p_actor_role" "text", "p_actor_department" "text", "p_visibility" "text", "p_severity" "text", "p_message" "text", "p_reason_code" "text", "p_reason_text" "text", "p_idempotency_key" "text", "p_event_version" integer, "p_command_name" "text", "p_command_id" "text", "p_causation_id" "text", "p_occurred_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."append_operational_event_v1"("p_event_type" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_title" "text", "p_source_application" "text", "p_correlation_id" "text", "p_metadata" "jsonb", "p_order_id" "uuid", "p_customer_id" "uuid", "p_queue_item_id" "uuid", "p_actor_id" "uuid", "p_actor_role" "text", "p_actor_department" "text", "p_visibility" "text", "p_severity" "text", "p_message" "text", "p_reason_code" "text", "p_reason_text" "text", "p_idempotency_key" "text", "p_event_version" integer, "p_command_name" "text", "p_command_id" "text", "p_causation_id" "text", "p_occurred_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_operational_event_v1"("p_event_type" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_title" "text", "p_source_application" "text", "p_correlation_id" "text", "p_metadata" "jsonb", "p_order_id" "uuid", "p_customer_id" "uuid", "p_queue_item_id" "uuid", "p_actor_id" "uuid", "p_actor_role" "text", "p_actor_department" "text", "p_visibility" "text", "p_severity" "text", "p_message" "text", "p_reason_code" "text", "p_reason_text" "text", "p_idempotency_key" "text", "p_event_version" integer, "p_command_name" "text", "p_command_id" "text", "p_causation_id" "text", "p_occurred_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_alias_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_alias_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_alias_draft"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_bom_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_bom_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_bom_draft"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_media_submission"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_media_submission"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_media_submission"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_moq_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_moq_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_moq_draft"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_pricing_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_pricing_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_pricing_draft"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_product_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_product_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_product_draft"("draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_catalogue_tag_draft"("draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_catalogue_tag_draft"("draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_catalogue_tag_draft"("draft_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_sales_order_draft_for_so_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_order_number_on_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."assign_order_number_on_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_order_number_on_insert"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."auth_buyer_company_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."auth_buyer_company_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."auth_buyer_company_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auth_buyer_company_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."block_orders_when_frozen"() TO "anon";
GRANT ALL ON FUNCTION "public"."block_orders_when_frozen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_orders_when_frozen"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."buyer_product_prices_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."buyer_product_prices_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."buyer_product_prices_v1"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."calculate_retry_delay_v1"("p_policy_key" "text", "p_attempt_count" integer, "p_jitter_seed" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calculate_retry_delay_v1"("p_policy_key" "text", "p_attempt_count" integer, "p_jitter_seed" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_retry_delay_v1"("p_policy_key" "text", "p_attempt_count" integer, "p_jitter_seed" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."catalogue_slugify_tag_part"("p_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."catalogue_slugify_tag_part"("p_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."catalogue_slugify_tag_part"("p_text" "text") TO "service_role";



GRANT ALL ON TABLE "public"."notification_outbox" TO "anon";
GRANT ALL ON TABLE "public"."notification_outbox" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_outbox" TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_notification_batch_v1"("p_worker_id" "text", "p_batch_size" integer, "p_lease_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_notification_batch_v1"("p_worker_id" "text", "p_batch_size" integer, "p_lease_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_provider_message_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_provider_message_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_sales_order_draft_atomic"("p_header" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_sales_order_drafts" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_sales_order_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_sales_order_drafts" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_whatsapp_sales_order_draft_from_operator"("_source_message_id" "uuid", "_resolved_sku" "text", "_resolved_product_name" "text", "_resolved_product_id" "uuid", "_confidence_band" "text", "_operator_decision" "text", "_quantity" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."customer_import_normalize_gst"("p_gst" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_gst"("p_gst" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_gst"("p_gst" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."customer_import_normalize_payment_terms"("p_terms" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_payment_terms"("p_terms" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_payment_terms"("p_terms" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."customer_import_normalize_phone_last10"("p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_phone_last10"("p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_import_normalize_phone_last10"("p_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."customer_import_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."customer_import_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_import_set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."customer_order_items_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."customer_order_items_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_order_items_v1"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."customer_order_status_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."customer_order_status_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_order_status_v1"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."customer_support_tickets_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."customer_support_tickets_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."customer_support_tickets_v1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."dispatch_completion_evidence_immutable"() TO "anon";
GRANT ALL ON FUNCTION "public"."dispatch_completion_evidence_immutable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispatch_completion_evidence_immutable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."dispatch_readiness_evidence_immutable"() TO "anon";
GRANT ALL ON FUNCTION "public"."dispatch_readiness_evidence_immutable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispatch_readiness_evidence_immutable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."dispatch_release_lineage_immutable"() TO "anon";
GRANT ALL ON FUNCTION "public"."dispatch_release_lineage_immutable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispatch_release_lineage_immutable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_profile_approval_for_staff"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_profile_approval_for_staff"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_profile_approval_for_staff"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_sales_order_draft_immutable_fields"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_sales_order_draft_immutable_fields"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_sales_order_draft_immutable_fields"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_notification_v1"("p_source_application" "text", "p_event_type" "text", "p_channel" "text", "p_message_body" "text", "p_idempotency_key" "text", "p_recipient_email" "text", "p_recipient_phone" "text", "p_priority" "text", "p_event_id" "uuid", "p_max_attempts" integer, "p_next_attempt_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_notification_v1"("p_source_application" "text", "p_event_type" "text", "p_channel" "text", "p_message_body" "text", "p_idempotency_key" "text", "p_recipient_email" "text", "p_recipient_phone" "text", "p_priority" "text", "p_event_id" "uuid", "p_max_attempts" integer, "p_next_attempt_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_notification_v1"("p_source_application" "text", "p_event_type" "text", "p_channel" "text", "p_message_body" "text", "p_idempotency_key" "text", "p_recipient_email" "text", "p_recipient_phone" "text", "p_priority" "text", "p_event_id" "uuid", "p_max_attempts" integer, "p_next_attempt_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fail_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_error" "text", "p_retry_delay_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fail_notification_v1"("p_notification_id" "uuid", "p_worker_id" "text", "p_error" "text", "p_retry_delay_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."finance_review_evidence_immutable"() TO "anon";
GRANT ALL ON FUNCTION "public"."finance_review_evidence_immutable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."finance_review_evidence_immutable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_oasis_sku"("_category_code" "text", "_division_code" "text", "_packaging_code" "text", "_subcategory_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_order_tracking_token"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_order_tracking_token"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_order_tracking_token"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_user_roles"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_user_roles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_user_roles"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_role_keys"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_role_keys"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_role_keys"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_price"("_product_id" "uuid", "_customer_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_price"("_product_id" "uuid", "_customer_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_price"("_product_id" "uuid", "_customer_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_price_usd"("_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_price_usd"("_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_price_usd"("_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_companies_is_frozen"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_companies_is_frozen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_companies_is_frozen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_is_frozen_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_is_frozen_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_is_frozen_changes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_credit_payment"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_credit_payment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_credit_payment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_active_company_membership"("p_user_id" "uuid", "p_company_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_active_company_membership"("p_user_id" "uuid", "p_company_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."has_active_company_membership"("p_user_id" "uuid", "p_company_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid", "p_branch_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid", "p_branch_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."has_app_permission"("p_user_id" "uuid", "p_permission_key" "text", "p_company_id" "uuid", "p_branch_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."has_catalogue_permission"("p_permission_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_catalogue_permission"("p_permission_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_catalogue_permission"("p_permission_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_step_up_auth"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_step_up_auth"() TO "service_role";
GRANT ALL ON FUNCTION "public"."has_step_up_auth"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."increment_announcement_counter"("ann_id" "uuid", "counter_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_announcement_counter"("ann_id" "uuid", "counter_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_announcement_counter"("ann_id" "uuid", "counter_name" "text") TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_inbound_messages" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_inbound_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_inbound_messages" TO "service_role";



GRANT ALL ON FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text", "_received_at" timestamp with time zone, "_raw_payload" "jsonb", "_resolver_status" "text", "_resolver_result_json" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text", "_received_at" timestamp with time zone, "_raw_payload" "jsonb", "_resolver_status" "text", "_resolver_result_json" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ingest_whatsapp_inbound_message"("_provider_message_id" "text", "_sender_phone" "text", "_sender_name" "text", "_message_body" "text", "_message_type" "text", "_received_at" timestamp with time zone, "_raw_payload" "jsonb", "_resolver_status" "text", "_resolver_result_json" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_account_manager"("_user_id" "uuid", "_company_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_account_manager"("_user_id" "uuid", "_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_account_manager"("_user_id" "uuid", "_company_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_catalogue_reviewer"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_catalogue_reviewer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_catalogue_reviewer"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_internal_staff"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_internal_staff"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_internal_staff"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_staff_role"("_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_staff_role"("_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_staff_role"("_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_team_member"("_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_team_member"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_team_member"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_team_member"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_whatsapp_inbox_reader"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."link_buyer_on_application_approval"() TO "anon";
GRANT ALL ON FUNCTION "public"."link_buyer_on_application_approval"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_buyer_on_application_approval"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_cart_failure"("_company_id" "uuid", "_error_message" "text", "_error_code" "text", "_context" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."log_cart_failure"("_company_id" "uuid", "_error_message" "text", "_error_code" "text", "_context" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_cart_failure"("_company_id" "uuid", "_error_message" "text", "_error_code" "text", "_context" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_admin_new_b2b_application"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_admin_new_b2b_application"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_admin_new_b2b_application"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ols_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."ols_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ols_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_inventory_movement_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_inventory_movement_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_inventory_movement_mutation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_operational_event_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_operational_event_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_operational_event_mutation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_operational_scan_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_operational_scan_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_operational_scan_mutation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_order_status_regression"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_order_status_regression"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_order_status_regression"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_profile_privilege_escalation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_profile_privilege_escalation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_profile_privilege_escalation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_stock_consumption_lineage_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_stock_consumption_lineage_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_stock_consumption_lineage_mutation"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."published_products_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."published_products_v1"() TO "anon";
GRANT ALL ON FUNCTION "public"."published_products_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."published_products_v1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_erp_order_financials"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_erp_order_financials"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_erp_order_financials"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_dead_letter_v1"("p_source_application" "text", "p_workload_type" "text", "p_source_table" "text", "p_source_record_id" "text", "p_policy_key" "text", "p_attempt_count" integer, "p_error_message" "text", "p_error_code" "text", "p_idempotency_key" "text", "p_context" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_dead_letter_v1"("p_source_application" "text", "p_workload_type" "text", "p_source_table" "text", "p_source_record_id" "text", "p_policy_key" "text", "p_attempt_count" integer, "p_error_message" "text", "p_error_code" "text", "p_idempotency_key" "text", "p_context" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_operator_decisions" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_operator_decisions" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_operator_decisions" TO "service_role";



GRANT ALL ON FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_whatsapp_operator_decision"("_source_message_id" "uuid", "_action" "text", "_sku" "text", "_product_name" "text", "_confidence_band" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_alias_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_alias_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_alias_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_bom_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_bom_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_bom_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_draft_internal"("p_draft_table" "text", "p_draft_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_media_submission"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_media_submission"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_media_submission"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_moq_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_moq_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_moq_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_pricing_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_pricing_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_pricing_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_product_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_product_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_product_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_catalogue_tag_draft"("draft_id" "uuid", "reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_catalogue_tag_draft"("draft_id" "uuid", "reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_catalogue_tag_draft"("draft_id" "uuid", "reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_sales_order_draft_atomic"("p_draft_id" "uuid", "p_actor_id" "uuid", "p_actor_name" "text", "p_rejection_reason" "text", "p_review_notes" "text", "p_metadata" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."resolve_dead_letter_v1"("p_dead_letter_id" "uuid", "p_status" "text", "p_resolution_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_dead_letter_v1"("p_dead_letter_id" "uuid", "p_status" "text", "p_resolution_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_dead_letter_v1"("p_dead_letter_id" "uuid", "p_status" "text", "p_resolution_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_order_qty_to_kg"("_product_id" "uuid", "_qty" numeric, "_input_uom" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_order_qty_to_kg"("_product_id" "uuid", "_qty" numeric, "_input_uom" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_order_qty_to_kg"("_product_id" "uuid", "_qty" numeric, "_input_uom" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_order_financials"("_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_order_financials"("_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."restore_order_financials"("_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_order_financials"("_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_customer_import_validation"("p_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."run_customer_import_validation"("p_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_customer_import_validation"("p_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_month_end_credit_lock"() TO "anon";
GRANT ALL ON FUNCTION "public"."run_month_end_credit_lock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_month_end_credit_lock"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."storage_object_path_matches_buyer_owned_order"("object_path" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text", "p_quantity_affected" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text", "p_quantity_affected" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_customer_support_ticket_v1"("p_order_id" "uuid", "p_issue_type" "text", "p_description" "text", "p_product_sku" "text", "p_quantity_affected" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_sales_order_draft_for_review_atomic"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."support_ticket_set_customer_context"() TO "anon";
GRANT ALL ON FUNCTION "public"."support_ticket_set_customer_context"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."support_ticket_set_customer_context"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_starter_packs_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_starter_packs_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_starter_packs_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."transition_sales_order_draft_status"("p_draft_id" "uuid", "p_expected_status" "text", "p_next_status" "text", "p_action" "text", "p_actor_id" "uuid", "p_actor_name" "text", "p_review_notes" "text", "p_rejection_reason" "text", "p_approver_id" "uuid", "p_approver_name" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_outstanding_on_order"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_outstanding_on_order"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_outstanding_on_order"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_sales_order_draft_operator_final"("p_draft_id" "uuid", "p_expected_extraction_request_key" "text", "p_operator_final_snapshot" "jsonb", "p_readiness_overall_score" integer, "p_readiness_dimensions" "jsonb", "p_lines" "jsonb", "p_actor_id" "uuid", "p_actor_name" "text", "p_audit_metadata" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_sales_order_draft_readiness"("p_dimensions" "jsonb") TO "service_role";






























GRANT ALL ON TABLE "public"."access_permissions" TO "anon";
GRANT ALL ON TABLE "public"."access_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."access_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."admin_manual_entries" TO "anon";
GRANT ALL ON TABLE "public"."admin_manual_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_manual_entries" TO "service_role";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";



GRANT ALL ON TABLE "public"."archive_logs" TO "anon";
GRANT ALL ON TABLE "public"."archive_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."archive_logs" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."auth_logs" TO "anon";
GRANT ALL ON TABLE "public"."auth_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."auth_logs" TO "service_role";



GRANT ALL ON TABLE "public"."b2b_applications" TO "anon";
GRANT ALL ON TABLE "public"."b2b_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."b2b_applications" TO "service_role";



GRANT ALL ON TABLE "public"."bi_monthly_ledgers" TO "anon";
GRANT ALL ON TABLE "public"."bi_monthly_ledgers" TO "authenticated";
GRANT ALL ON TABLE "public"."bi_monthly_ledgers" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_ai_studio_draft_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_ai_studio_draft_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_ai_studio_draft_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_ai_studio_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_ai_studio_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_ai_studio_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_alias_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_alias_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_alias_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_approval_audit" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_approval_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_approval_audit" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_bom_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_bom_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_bom_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_media_submissions" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_media_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_media_submissions" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_moq_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_moq_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_moq_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_pricing_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_pricing_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_pricing_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_product_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_product_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_product_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_product_mappings" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_product_mappings" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_product_mappings" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_sync_events" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_sync_events" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_sync_events" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_tag_drafts" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_tag_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_tag_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."catalogue_versions" TO "anon";
GRANT ALL ON TABLE "public"."catalogue_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."catalogue_versions" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON TABLE "public"."client_interactions" TO "anon";
GRANT ALL ON TABLE "public"."client_interactions" TO "authenticated";
GRANT ALL ON TABLE "public"."client_interactions" TO "service_role";



GRANT ALL ON TABLE "public"."daily_production_logs" TO "anon";
GRANT ALL ON TABLE "public"."daily_production_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_production_logs" TO "service_role";



GRANT ALL ON TABLE "public"."cmd_department_health" TO "anon";
GRANT ALL ON TABLE "public"."cmd_department_health" TO "authenticated";
GRANT ALL ON TABLE "public"."cmd_department_health" TO "service_role";



GRANT ALL ON TABLE "public"."commission_payouts" TO "anon";
GRANT ALL ON TABLE "public"."commission_payouts" TO "authenticated";
GRANT ALL ON TABLE "public"."commission_payouts" TO "service_role";



GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON TABLE "public"."credit_requests" TO "anon";
GRANT ALL ON TABLE "public"."credit_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_requests" TO "service_role";



GRANT ALL ON TABLE "public"."credit_rescue_events" TO "anon";
GRANT ALL ON TABLE "public"."credit_rescue_events" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_rescue_events" TO "service_role";



GRANT ALL ON TABLE "public"."crm_tasks" TO "anon";
GRANT ALL ON TABLE "public"."crm_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."customer_import_batches" TO "anon";
GRANT ALL ON TABLE "public"."customer_import_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_import_batches" TO "service_role";



GRANT ALL ON TABLE "public"."customer_import_company_candidates" TO "anon";
GRANT ALL ON TABLE "public"."customer_import_company_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_import_company_candidates" TO "service_role";



GRANT ALL ON TABLE "public"."customer_import_contact_candidates" TO "anon";
GRANT ALL ON TABLE "public"."customer_import_contact_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_import_contact_candidates" TO "service_role";



GRANT ALL ON TABLE "public"."customer_import_duplicate_review" TO "anon";
GRANT ALL ON TABLE "public"."customer_import_duplicate_review" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_import_duplicate_review" TO "service_role";



GRANT ALL ON TABLE "public"."customer_import_raw" TO "anon";
GRANT ALL ON TABLE "public"."customer_import_raw" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_import_raw" TO "service_role";



GRANT ALL ON TABLE "public"."dead_letter_entries" TO "anon";
GRANT ALL ON TABLE "public"."dead_letter_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."dead_letter_entries" TO "service_role";



GRANT ALL ON TABLE "public"."debug_webhooks" TO "anon";
GRANT ALL ON TABLE "public"."debug_webhooks" TO "authenticated";
GRANT ALL ON TABLE "public"."debug_webhooks" TO "service_role";



GRANT ALL ON TABLE "public"."delivery_addresses" TO "anon";
GRANT ALL ON TABLE "public"."delivery_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_addresses" TO "service_role";



GRANT ALL ON TABLE "public"."dispatch_cartons" TO "anon";
GRANT ALL ON TABLE "public"."dispatch_cartons" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_cartons" TO "service_role";



GRANT ALL ON TABLE "public"."dispatch_completion_evidence" TO "anon";
GRANT ALL ON TABLE "public"."dispatch_completion_evidence" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_completion_evidence" TO "service_role";



GRANT ALL ON TABLE "public"."dispatch_readiness_evidence" TO "anon";
GRANT ALL ON TABLE "public"."dispatch_readiness_evidence" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_readiness_evidence" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_release_lineage" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_release_lineage" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_release_lineage" TO "service_role";



GRANT ALL ON TABLE "public"."dispatches" TO "anon";
GRANT ALL ON TABLE "public"."dispatches" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatches" TO "service_role";



GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";



GRANT ALL ON TABLE "public"."employee_performance_logs" TO "anon";
GRANT ALL ON TABLE "public"."employee_performance_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_performance_logs" TO "service_role";



GRANT ALL ON TABLE "public"."exchange_rates" TO "anon";
GRANT ALL ON TABLE "public"."exchange_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."exchange_rates" TO "service_role";



GRANT ALL ON TABLE "public"."factory_holidays" TO "anon";
GRANT ALL ON TABLE "public"."factory_holidays" TO "authenticated";
GRANT ALL ON TABLE "public"."factory_holidays" TO "service_role";



GRANT ALL ON TABLE "public"."factory_inventory" TO "anon";
GRANT ALL ON TABLE "public"."factory_inventory" TO "authenticated";
GRANT ALL ON TABLE "public"."factory_inventory" TO "service_role";



GRANT ALL ON TABLE "public"."finance_review_evidence" TO "anon";
GRANT ALL ON TABLE "public"."finance_review_evidence" TO "authenticated";
GRANT ALL ON TABLE "public"."finance_review_evidence" TO "service_role";



GRANT ALL ON TABLE "public"."freight_ledger" TO "anon";
GRANT ALL ON TABLE "public"."freight_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."freight_ledger" TO "service_role";



GRANT ALL ON TABLE "public"."identity_profiles" TO "anon";
GRANT ALL ON TABLE "public"."identity_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."identity_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_adjustments" TO "anon";
GRANT ALL ON TABLE "public"."inventory_adjustments" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_adjustments" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_items" TO "anon";
GRANT ALL ON TABLE "public"."inventory_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_items" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."inventory_movements" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."inventory_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_movements" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_reservation_allocations" TO "anon";
GRANT ALL ON TABLE "public"."inventory_reservation_allocations" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_reservation_allocations" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_reservations" TO "anon";
GRANT ALL ON TABLE "public"."inventory_reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_reservations" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_stock_balances" TO "anon";
GRANT ALL ON TABLE "public"."inventory_stock_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_stock_balances" TO "service_role";



GRANT ALL ON TABLE "public"."invoices" TO "anon";
GRANT ALL ON TABLE "public"."invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."invoices" TO "service_role";



GRANT ALL ON TABLE "public"."inward_material_advice" TO "anon";
GRANT ALL ON TABLE "public"."inward_material_advice" TO "authenticated";
GRANT ALL ON TABLE "public"."inward_material_advice" TO "service_role";



GRANT ALL ON TABLE "public"."inward_material_items" TO "anon";
GRANT ALL ON TABLE "public"."inward_material_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inward_material_items" TO "service_role";



GRANT ALL ON TABLE "public"."ledger_disputes" TO "anon";
GRANT ALL ON TABLE "public"."ledger_disputes" TO "authenticated";
GRANT ALL ON TABLE "public"."ledger_disputes" TO "service_role";



GRANT ALL ON TABLE "public"."moq_rules" TO "anon";
GRANT ALL ON TABLE "public"."moq_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."moq_rules" TO "service_role";



GRANT ALL ON TABLE "public"."notification_events" TO "anon";
GRANT ALL ON TABLE "public"."notification_events" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_events" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."ols_audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."ols_audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."ols_carton_contents" TO "anon";
GRANT ALL ON TABLE "public"."ols_carton_contents" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_carton_contents" TO "service_role";



GRANT ALL ON TABLE "public"."ols_cartons" TO "anon";
GRANT ALL ON TABLE "public"."ols_cartons" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_cartons" TO "service_role";



GRANT ALL ON TABLE "public"."ols_departments" TO "anon";
GRANT ALL ON TABLE "public"."ols_departments" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_departments" TO "service_role";



GRANT ALL ON TABLE "public"."ols_dispatch_document_bundles" TO "anon";
GRANT ALL ON TABLE "public"."ols_dispatch_document_bundles" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_dispatch_document_bundles" TO "service_role";



GRANT ALL ON TABLE "public"."ols_dpl_cartons" TO "anon";
GRANT ALL ON TABLE "public"."ols_dpl_cartons" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_dpl_cartons" TO "service_role";



GRANT ALL ON TABLE "public"."ols_dpl_documents" TO "anon";
GRANT ALL ON TABLE "public"."ols_dpl_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_dpl_documents" TO "service_role";



GRANT ALL ON TABLE "public"."ols_finance_pi" TO "anon";
GRANT ALL ON TABLE "public"."ols_finance_pi" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_finance_pi" TO "service_role";



GRANT ALL ON TABLE "public"."ols_finance_pi_cartons" TO "anon";
GRANT ALL ON TABLE "public"."ols_finance_pi_cartons" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_finance_pi_cartons" TO "service_role";



GRANT ALL ON TABLE "public"."ols_finance_pi_lines" TO "anon";
GRANT ALL ON TABLE "public"."ols_finance_pi_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_finance_pi_lines" TO "service_role";



GRANT ALL ON TABLE "public"."ols_gate_scans" TO "anon";
GRANT ALL ON TABLE "public"."ols_gate_scans" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_gate_scans" TO "service_role";



GRANT ALL ON TABLE "public"."ols_inventory_movements" TO "anon";
GRANT ALL ON TABLE "public"."ols_inventory_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_inventory_movements" TO "service_role";



GRANT ALL ON TABLE "public"."ols_label_templates" TO "anon";
GRANT ALL ON TABLE "public"."ols_label_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_label_templates" TO "service_role";



GRANT ALL ON TABLE "public"."ols_manual_override_logs" TO "anon";
GRANT ALL ON TABLE "public"."ols_manual_override_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_manual_override_logs" TO "service_role";



GRANT ALL ON TABLE "public"."ols_orders_cache" TO "anon";
GRANT ALL ON TABLE "public"."ols_orders_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_orders_cache" TO "service_role";



GRANT ALL ON TABLE "public"."ols_permissions" TO "anon";
GRANT ALL ON TABLE "public"."ols_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."ols_print_jobs" TO "anon";
GRANT ALL ON TABLE "public"."ols_print_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_print_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."ols_print_logs" TO "anon";
GRANT ALL ON TABLE "public"."ols_print_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_print_logs" TO "service_role";



GRANT ALL ON TABLE "public"."ols_printer_settings" TO "anon";
GRANT ALL ON TABLE "public"."ols_printer_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_printer_settings" TO "service_role";



GRANT ALL ON TABLE "public"."ols_printers" TO "anon";
GRANT ALL ON TABLE "public"."ols_printers" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_printers" TO "service_role";



GRANT ALL ON TABLE "public"."ols_production_batches" TO "anon";
GRANT ALL ON TABLE "public"."ols_production_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_production_batches" TO "service_role";



GRANT ALL ON TABLE "public"."ols_production_labels" TO "anon";
GRANT ALL ON TABLE "public"."ols_production_labels" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_production_labels" TO "service_role";



GRANT ALL ON TABLE "public"."ols_products_cache" TO "anon";
GRANT ALL ON TABLE "public"."ols_products_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_products_cache" TO "service_role";



GRANT ALL ON TABLE "public"."ols_profiles_light" TO "anon";
GRANT ALL ON TABLE "public"."ols_profiles_light" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_profiles_light" TO "service_role";



GRANT ALL ON TABLE "public"."ols_reprint_requests" TO "anon";
GRANT ALL ON TABLE "public"."ols_reprint_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_reprint_requests" TO "service_role";



GRANT ALL ON TABLE "public"."ols_scan_history" TO "anon";
GRANT ALL ON TABLE "public"."ols_scan_history" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_scan_history" TO "service_role";



GRANT ALL ON TABLE "public"."ols_settings" TO "anon";
GRANT ALL ON TABLE "public"."ols_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_settings" TO "service_role";



GRANT ALL ON TABLE "public"."ols_shipping_labels" TO "anon";
GRANT ALL ON TABLE "public"."ols_shipping_labels" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_shipping_labels" TO "service_role";



GRANT ALL ON TABLE "public"."ols_stock_units" TO "anon";
GRANT ALL ON TABLE "public"."ols_stock_units" TO "authenticated";
GRANT ALL ON TABLE "public"."ols_stock_units" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."operational_events" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."operational_events" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_events" TO "service_role";



GRANT ALL ON TABLE "public"."operational_queue_assignments" TO "anon";
GRANT ALL ON TABLE "public"."operational_queue_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_queue_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."operational_queue_items" TO "anon";
GRANT ALL ON TABLE "public"."operational_queue_items" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_queue_items" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."operational_scan_records" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."operational_scan_records" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_scan_records" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."operational_search_index" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."operational_search_index" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_search_index" TO "service_role";



GRANT ALL ON TABLE "public"."order_attachments" TO "anon";
GRANT ALL ON TABLE "public"."order_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."order_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."order_items" TO "anon";
GRANT ALL ON TABLE "public"."order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."order_items" TO "service_role";



GRANT ALL ON TABLE "public"."order_payments" TO "anon";
GRANT ALL ON TABLE "public"."order_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."order_payments" TO "service_role";



GRANT ALL ON TABLE "public"."order_returns" TO "anon";
GRANT ALL ON TABLE "public"."order_returns" TO "authenticated";
GRANT ALL ON TABLE "public"."order_returns" TO "service_role";



GRANT ALL ON TABLE "public"."order_status_history" TO "anon";
GRANT ALL ON TABLE "public"."order_status_history" TO "authenticated";
GRANT ALL ON TABLE "public"."order_status_history" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."org_branches" TO "anon";
GRANT ALL ON TABLE "public"."org_branches" TO "authenticated";
GRANT ALL ON TABLE "public"."org_branches" TO "service_role";



GRANT ALL ON TABLE "public"."org_companies" TO "anon";
GRANT ALL ON TABLE "public"."org_companies" TO "authenticated";
GRANT ALL ON TABLE "public"."org_companies" TO "service_role";



GRANT ALL ON TABLE "public"."org_contacts" TO "anon";
GRANT ALL ON TABLE "public"."org_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."org_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."org_membership_branch_scopes" TO "anon";
GRANT ALL ON TABLE "public"."org_membership_branch_scopes" TO "authenticated";
GRANT ALL ON TABLE "public"."org_membership_branch_scopes" TO "service_role";



GRANT ALL ON TABLE "public"."org_membership_roles" TO "anon";
GRANT ALL ON TABLE "public"."org_membership_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."org_membership_roles" TO "service_role";



GRANT ALL ON TABLE "public"."org_memberships" TO "anon";
GRANT ALL ON TABLE "public"."org_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."org_memberships" TO "service_role";



GRANT ALL ON TABLE "public"."packing_lists" TO "anon";
GRANT ALL ON TABLE "public"."packing_lists" TO "authenticated";
GRANT ALL ON TABLE "public"."packing_lists" TO "service_role";



GRANT ALL ON TABLE "public"."permissions" TO "anon";
GRANT ALL ON TABLE "public"."permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."permissions" TO "service_role";



GRANT ALL ON TABLE "public"."portal_access_invites" TO "anon";
GRANT ALL ON TABLE "public"."portal_access_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."portal_access_invites" TO "service_role";



GRANT ALL ON TABLE "public"."premium_announcements" TO "anon";
GRANT ALL ON TABLE "public"."premium_announcements" TO "authenticated";
GRANT ALL ON TABLE "public"."premium_announcements" TO "service_role";



GRANT ALL ON TABLE "public"."pricing_slabs" TO "anon";
GRANT ALL ON TABLE "public"."pricing_slabs" TO "authenticated";
GRANT ALL ON TABLE "public"."pricing_slabs" TO "service_role";



GRANT ALL ON TABLE "public"."product_aliases" TO "anon";
GRANT ALL ON TABLE "public"."product_aliases" TO "authenticated";
GRANT ALL ON TABLE "public"."product_aliases" TO "service_role";



GRANT ALL ON TABLE "public"."product_bom" TO "anon";
GRANT ALL ON TABLE "public"."product_bom" TO "authenticated";
GRANT ALL ON TABLE "public"."product_bom" TO "service_role";



GRANT ALL ON TABLE "public"."product_media" TO "anon";
GRANT ALL ON TABLE "public"."product_media" TO "authenticated";
GRANT ALL ON TABLE "public"."product_media" TO "service_role";



GRANT ALL ON TABLE "public"."product_moq_rules" TO "anon";
GRANT ALL ON TABLE "public"."product_moq_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."product_moq_rules" TO "service_role";



GRANT ALL ON TABLE "public"."product_pricing_rules" TO "anon";
GRANT ALL ON TABLE "public"."product_pricing_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."product_pricing_rules" TO "service_role";



GRANT ALL ON TABLE "public"."product_tag_mapping" TO "anon";
GRANT ALL ON TABLE "public"."product_tag_mapping" TO "authenticated";
GRANT ALL ON TABLE "public"."product_tag_mapping" TO "service_role";



GRANT ALL ON TABLE "public"."product_tags" TO "anon";
GRANT ALL ON TABLE "public"."product_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."product_tags" TO "service_role";



GRANT ALL ON TABLE "public"."product_variants" TO "anon";
GRANT ALL ON TABLE "public"."product_variants" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variants" TO "service_role";



GRANT ALL ON TABLE "public"."production_issues" TO "anon";
GRANT ALL ON TABLE "public"."production_issues" TO "authenticated";
GRANT ALL ON TABLE "public"."production_issues" TO "service_role";



GRANT ALL ON TABLE "public"."production_jobs" TO "anon";
GRANT ALL ON TABLE "public"."production_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."production_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."production_pauses" TO "anon";
GRANT ALL ON TABLE "public"."production_pauses" TO "authenticated";
GRANT ALL ON TABLE "public"."production_pauses" TO "service_role";



GRANT ALL ON TABLE "public"."production_rgs_transfers" TO "anon";
GRANT ALL ON TABLE "public"."production_rgs_transfers" TO "authenticated";
GRANT ALL ON TABLE "public"."production_rgs_transfers" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."profile_change_requests" TO "anon";
GRANT ALL ON TABLE "public"."profile_change_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_change_requests" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."realtime_subscription_contracts" TO "anon";
GRANT ALL ON TABLE "public"."realtime_subscription_contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."realtime_subscription_contracts" TO "service_role";



GRANT ALL ON TABLE "public"."realtime_contract_health" TO "anon";
GRANT ALL ON TABLE "public"."realtime_contract_health" TO "authenticated";
GRANT ALL ON TABLE "public"."realtime_contract_health" TO "service_role";



GRANT ALL ON TABLE "public"."retry_policies" TO "anon";
GRANT ALL ON TABLE "public"."retry_policies" TO "authenticated";
GRANT ALL ON TABLE "public"."retry_policies" TO "service_role";



GRANT ALL ON TABLE "public"."role_permission_grants" TO "anon";
GRANT ALL ON TABLE "public"."role_permission_grants" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permission_grants" TO "service_role";



GRANT ALL ON TABLE "public"."role_permission_map" TO "anon";
GRANT ALL ON TABLE "public"."role_permission_map" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permission_map" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."sales_order_draft_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."sales_order_draft_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_order_draft_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."sales_order_draft_lines" TO "anon";
GRANT ALL ON TABLE "public"."sales_order_draft_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_order_draft_lines" TO "service_role";



GRANT ALL ON TABLE "public"."sales_order_drafts" TO "anon";
GRANT ALL ON TABLE "public"."sales_order_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_order_drafts" TO "service_role";



GRANT ALL ON TABLE "public"."shadow_clients" TO "anon";
GRANT ALL ON TABLE "public"."shadow_clients" TO "authenticated";
GRANT ALL ON TABLE "public"."shadow_clients" TO "service_role";



GRANT ALL ON TABLE "public"."sku_code_rules" TO "anon";
GRANT ALL ON TABLE "public"."sku_code_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."sku_code_rules" TO "service_role";



GRANT ALL ON TABLE "public"."starter_packs" TO "anon";
GRANT ALL ON TABLE "public"."starter_packs" TO "authenticated";
GRANT ALL ON TABLE "public"."starter_packs" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."stock_consumption_lineage" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."stock_consumption_lineage" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_consumption_lineage" TO "service_role";



GRANT ALL ON TABLE "public"."stock_logs" TO "anon";
GRANT ALL ON TABLE "public"."stock_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_logs" TO "service_role";



GRANT ALL ON TABLE "public"."storage_bucket_contracts" TO "anon";
GRANT ALL ON TABLE "public"."storage_bucket_contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."storage_bucket_contracts" TO "service_role";



GRANT ALL ON TABLE "public"."store_requisition_items" TO "anon";
GRANT ALL ON TABLE "public"."store_requisition_items" TO "authenticated";
GRANT ALL ON TABLE "public"."store_requisition_items" TO "service_role";



GRANT ALL ON TABLE "public"."store_requisitions" TO "anon";
GRANT ALL ON TABLE "public"."store_requisitions" TO "authenticated";
GRANT ALL ON TABLE "public"."store_requisitions" TO "service_role";



GRANT ALL ON TABLE "public"."suggested_orders" TO "anon";
GRANT ALL ON TABLE "public"."suggested_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."suggested_orders" TO "service_role";



GRANT ALL ON TABLE "public"."support_tickets" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."support_tickets" TO "authenticated";



GRANT ALL ON TABLE "public"."system_alerts" TO "anon";
GRANT ALL ON TABLE "public"."system_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."system_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."system_settings" TO "anon";
GRANT ALL ON TABLE "public"."system_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."system_settings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."system_settings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."system_settings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."system_settings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tickets" TO "service_role";



GRANT ALL ON TABLE "public"."user_favorites" TO "anon";
GRANT ALL ON TABLE "public"."user_favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."user_favorites" TO "service_role";



GRANT ALL ON TABLE "public"."user_role_map" TO "anon";
GRANT ALL ON TABLE "public"."user_role_map" TO "authenticated";
GRANT ALL ON TABLE "public"."user_role_map" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_batch_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_batch_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_batch_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_company_phone_slots" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_company_phone_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_company_phone_slots" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_company_required_gaps" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_company_required_gaps" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_company_required_gaps" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_contact_phone_gaps" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_contact_phone_gaps" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_contact_phone_gaps" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_duplicate_contact_phone_in_batch" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_contact_phone_in_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_contact_phone_in_batch" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_duplicate_gst_in_batch" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_gst_in_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_gst_in_batch" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_duplicate_name_in_batch" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_name_in_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_name_in_batch" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_any_in_batch" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_any_in_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_any_in_batch" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_in_batch" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_in_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_duplicate_phone_in_batch" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_gst_match_existing" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_gst_match_existing" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_gst_match_existing" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_orphan_contacts" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_orphan_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_orphan_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."v_customer_import_promotion_readiness" TO "anon";
GRANT ALL ON TABLE "public"."v_customer_import_promotion_readiness" TO "authenticated";
GRANT ALL ON TABLE "public"."v_customer_import_promotion_readiness" TO "service_role";



GRANT ALL ON TABLE "public"."wallet_transactions" TO "anon";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_automations" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_automations" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_automations" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_buffer" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_buffer" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_buffer" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_config" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_config" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_config" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_contacts" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_message_packets" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_message_packets" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_message_packets" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_messages" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_messages" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_override_log" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_override_log" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_override_log" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_stitched_packets" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_stitched_packets" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_stitched_packets" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_studio_inbox_bridge_state" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_studio_inbox_bridge_state" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_studio_inbox_bridge_state" TO "service_role";



GRANT ALL ON TABLE "public"."whatsapp_suggestions_log" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_suggestions_log" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_suggestions_log" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























-- Canonical baseline supplement: custom policies on the Supabase-managed
-- storage.objects table are excluded from the default schema-only dump.
-- These definitions were verified read-only against production on 2026-07-27.

DROP POLICY IF EXISTS "Authenticated upload own receipts" ON "storage"."objects";
CREATE POLICY "Authenticated upload own receipts"
ON "storage"."objects" FOR INSERT TO "authenticated"
WITH CHECK (
  ("bucket_id" = 'receipts')
  AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::text)
);

DROP POLICY IF EXISTS "Authenticated upload own trade documents" ON "storage"."objects";
CREATE POLICY "Authenticated upload own trade documents"
ON "storage"."objects" FOR INSERT TO "authenticated"
WITH CHECK (
  ("bucket_id" = 'trade-documents')
  AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::text)
);

DROP POLICY IF EXISTS "Internal staff delete product media" ON "storage"."objects";
CREATE POLICY "Internal staff delete product media"
ON "storage"."objects" FOR DELETE TO "authenticated"
USING (
  ("bucket_id" = ANY (ARRAY['product-images'::text, 'product-media'::text]))
  AND "public"."is_internal_staff"("auth"."uid"())
);

DROP POLICY IF EXISTS "Internal staff insert product media" ON "storage"."objects";
CREATE POLICY "Internal staff insert product media"
ON "storage"."objects" FOR INSERT TO "authenticated"
WITH CHECK (
  ("bucket_id" = ANY (ARRAY['product-images'::text, 'product-media'::text]))
  AND "public"."is_internal_staff"("auth"."uid"())
);

DROP POLICY IF EXISTS "Internal staff read whatsapp attachments" ON "storage"."objects";
CREATE POLICY "Internal staff read whatsapp attachments"
ON "storage"."objects" FOR SELECT TO "authenticated"
USING (
  ("bucket_id" = 'whatsapp_attachments')
  AND "public"."is_internal_staff"("auth"."uid"())
);

DROP POLICY IF EXISTS "Internal staff update product media" ON "storage"."objects";
CREATE POLICY "Internal staff update product media"
ON "storage"."objects" FOR UPDATE TO "authenticated"
USING (
  ("bucket_id" = ANY (ARRAY['product-images'::text, 'product-media'::text]))
  AND "public"."is_internal_staff"("auth"."uid"())
)
WITH CHECK (
  ("bucket_id" = ANY (ARRAY['product-images'::text, 'product-media'::text]))
  AND "public"."is_internal_staff"("auth"."uid"())
);

DROP POLICY IF EXISTS "Internal staff upload whatsapp attachments" ON "storage"."objects";
CREATE POLICY "Internal staff upload whatsapp attachments"
ON "storage"."objects" FOR INSERT TO "authenticated"
WITH CHECK (
  ("bucket_id" = 'whatsapp_attachments')
  AND "public"."is_internal_staff"("auth"."uid"())
);

DROP POLICY IF EXISTS "Only admins can view trade documents" ON "storage"."objects";
CREATE POLICY "Only admins can view trade documents"
ON "storage"."objects" FOR SELECT TO PUBLIC
USING (
  ("bucket_id" = 'trade-documents')
  AND (
    SELECT "users"."role"
    FROM "public"."users"
    WHERE "users"."id" = "auth"."uid"()
    LIMIT 1
  ) = ANY (ARRAY['super_admin'::text, 'admin'::text])
);

DROP POLICY IF EXISTS "Owner or staff delete receipts" ON "storage"."objects";
CREATE POLICY "Owner or staff delete receipts"
ON "storage"."objects" FOR DELETE TO "authenticated"
USING (
  ("bucket_id" = 'receipts')
  AND (
    (("storage"."foldername"("name"))[1] = ("auth"."uid"())::text)
    OR "public"."is_internal_staff"("auth"."uid"())
  )
);

DROP POLICY IF EXISTS "Owner or staff read receipts" ON "storage"."objects";
CREATE POLICY "Owner or staff read receipts"
ON "storage"."objects" FOR SELECT TO "authenticated"
USING (
  ("bucket_id" = 'receipts')
  AND (
    (("storage"."foldername"("name"))[1] = ("auth"."uid"())::text)
    OR "public"."is_internal_staff"("auth"."uid"())
  )
);

DROP POLICY IF EXISTS "Public read product media buckets" ON "storage"."objects";
CREATE POLICY "Public read product media buckets"
ON "storage"."objects" FOR SELECT TO PUBLIC
USING (
  "bucket_id" = ANY (
    ARRAY['product-media'::text, 'product-images'::text, 'generated-media'::text]
  )
);

DROP POLICY IF EXISTS "Public read product-images" ON "storage"."objects";
CREATE POLICY "Public read product-images"
ON "storage"."objects" FOR SELECT TO PUBLIC
USING ("bucket_id" = 'product-images');

DROP POLICY IF EXISTS "Public read product-media" ON "storage"."objects";
CREATE POLICY "Public read product-media"
ON "storage"."objects" FOR SELECT TO PUBLIC
USING ("bucket_id" = 'product-media');

DROP POLICY IF EXISTS "Staff read all trade documents" ON "storage"."objects";
CREATE POLICY "Staff read all trade documents"
ON "storage"."objects" FOR SELECT TO "authenticated"
USING (
  ("bucket_id" = 'trade-documents')
  AND (
    "public"."is_internal_staff"("auth"."uid"())
    OR "public"."get_user_role"("auth"."uid"()) = ANY (
      ARRAY['admin'::text, 'super_admin'::text]
    )
  )
);

DROP POLICY IF EXISTS "Users read own trade documents" ON "storage"."objects";
CREATE POLICY "Users read own trade documents"
ON "storage"."objects" FOR SELECT TO "authenticated"
USING (
  ("bucket_id" = 'trade-documents')
  AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::text)
);
