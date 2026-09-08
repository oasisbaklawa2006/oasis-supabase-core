-- MACRO-TRACE Core authority completion.
-- Closes the remaining server-authority gaps required by oasis-trace PR #37:
--   1) atomic server allocation for Trace-owned identities;
--   2) server-authenticated handover evidence with actor/time binding;
--   3) authenticated carton finalisation with evidence persisted atomically.
-- Forward-only. Do not edit historical Trace Gate 3 migrations.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.ols_trace_identity_sequences (
  kind text NOT NULL,
  bucket_date date NOT NULL,
  next_value bigint NOT NULL CHECK (next_value > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kind, bucket_date)
);

ALTER TABLE public.ols_trace_identity_sequences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ols_trace_identity_sequences FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ols_trace_identity_sequences TO service_role;

CREATE TABLE IF NOT EXISTS public.ols_trace_handover_signing_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key_version integer NOT NULL UNIQUE CHECK (key_version > 0),
  secret bytea NOT NULL CHECK (octet_length(secret) >= 32),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ols_trace_handover_one_active_key_uniq
  ON public.ols_trace_handover_signing_keys ((active))
  WHERE active;

ALTER TABLE public.ols_trace_handover_signing_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ols_trace_handover_signing_keys FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ols_trace_handover_signing_keys TO service_role;

INSERT INTO public.ols_trace_handover_signing_keys(key_version, secret, active)
SELECT 1, extensions.gen_random_bytes(32), true
WHERE NOT EXISTS (
  SELECT 1 FROM public.ols_trace_handover_signing_keys WHERE active
);

CREATE OR REPLACE FUNCTION public.trace_allocate_identity_v1(p_kind text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_action text;
  v_prefix text;
  v_width integer;
  v_seq bigint;
  v_max bigint;
BEGIN
  CASE v_kind
    WHEN 'production_label' THEN v_action := 'production'; v_prefix := 'PL';  v_width := 4;
    WHEN 'batch'            THEN v_action := 'production'; v_prefix := 'BAT'; v_width := 3;
    WHEN 'legacy_carton'    THEN v_action := 'packing';    v_prefix := 'CTN'; v_width := 4;
    WHEN 'dpl'              THEN v_action := 'dispatch';   v_prefix := 'DPL'; v_width := 3;
    WHEN 'pi'               THEN v_action := 'finance';    v_prefix := 'PI';  v_width := 3;
    WHEN 'shipping'         THEN v_action := 'dispatch';   v_prefix := 'SHP'; v_width := 4;
    ELSE
      RAISE EXCEPTION 'TRACE_IDENTITY_KIND_INVALID: %', p_kind USING ERRCODE = '22023';
  END CASE;

  PERFORM public.trace_assert_role_v1(v_action);

  INSERT INTO public.ols_trace_identity_sequences(kind, bucket_date, next_value, updated_at)
  VALUES(v_kind, current_date, 1, now())
  ON CONFLICT (kind, bucket_date)
  DO UPDATE SET
    next_value = public.ols_trace_identity_sequences.next_value + 1,
    updated_at = now()
  RETURNING next_value INTO v_seq;

  v_max := power(10::numeric, v_width)::bigint - 1;
  IF v_seq > v_max THEN
    RAISE EXCEPTION 'TRACE_IDENTITY_SEQUENCE_EXHAUSTED: % %', v_kind, current_date
      USING ERRCODE = '54000';
  END IF;

  RETURN v_prefix || '-' || to_char(current_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, v_width, '0');
END
$$;

REVOKE ALL ON FUNCTION public.trace_allocate_identity_v1(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trace_allocate_identity_v1(text) TO authenticated, service_role;

-- Replace the existing production mutation in-place so authenticated callers can
-- no longer choose batch_no / label_no. Client-supplied identifier fields are ignored.
CREATE OR REPLACE FUNCTION public.trace_create_production_v1(
  p_input jsonb,
  p_labels jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  f text := md5(p_input::text || p_labels::text);
  prior record;
  b public.ols_production_batches;
  l public.ols_production_labels;
  item jsonb;
  out_labels jsonb := '[]'::jsonb;
  result jsonb;
  v_batch_no text;
  v_label_no text;
BEGIN
  PERFORM public.trace_assert_role_v1('production');
  IF nullif(btrim(p_idempotency_key), '') IS NULL
     OR jsonb_typeof(p_labels) <> 'array'
     OR jsonb_array_length(p_labels) < 1
     OR jsonb_array_length(p_labels) > 500 THEN
    RAISE EXCEPTION 'INVALID_TRACE_MUTATION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  SELECT payload_fingerprint, response
    INTO prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.payload_fingerprint <> f THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN prior.response;
  END IF;

  v_batch_no := public.trace_allocate_identity_v1('batch');
  INSERT INTO public.ols_production_batches(
    batch_no, product_id, department_id, shift, mfg_date, shelf_life_days,
    qc_status, remarks, created_by
  )
  VALUES(
    v_batch_no,
    (p_input->>'product_id')::uuid,
    (p_input->>'department_id')::uuid,
    p_input->>'shift',
    (p_input->>'mfg_date')::date,
    (p_input->>'shelf_life_days')::int,
    p_input->>'qc_status',
    p_input->>'remarks',
    auth.uid()
  )
  RETURNING * INTO b;

  FOR item IN SELECT value FROM jsonb_array_elements(p_labels)
  LOOP
    v_label_no := public.trace_allocate_identity_v1('production_label');
    INSERT INTO public.ols_production_labels(
      label_no, batch_id, product_id, department_id, tray_serial,
      net_weight, gross_weight, mfg_date, best_before, qc_status,
      operator_name, status, metadata, created_by
    )
    VALUES(
      v_label_no,
      b.id,
      (item->>'product_id')::uuid,
      (item->>'department_id')::uuid,
      item->>'tray_serial',
      (item->>'net_weight')::numeric,
      (item->>'gross_weight')::numeric,
      (item->>'mfg_date')::date,
      (item->>'best_before')::date,
      item->>'qc_status',
      item->>'operator_name',
      'active',
      coalesce(item->'metadata', '{}'::jsonb),
      auth.uid()
    )
    RETURNING * INTO l;

    INSERT INTO public.ols_stock_units(production_label_id, current_location, current_status)
    VALUES(l.id, 'store', 'in_stock');

    INSERT INTO public.ols_inventory_movements(
      production_label_id, from_location, to_location, movement_type, reference_no, user_id
    )
    VALUES(l.id, 'production', 'store', 'production_inward', b.batch_no, auth.uid());

    out_labels := out_labels || jsonb_build_array(to_jsonb(l));
  END LOOP;

  result := jsonb_build_object('batch', to_jsonb(b), 'labels', out_labels);

  INSERT INTO public.ols_audit_logs(
    action, entity_type, entity_id, user_id, details, idempotency_key
  ) VALUES(
    'trace_production_created', 'production_batch', b.id, auth.uid(),
    jsonb_build_object('label_count', jsonb_array_length(p_labels), 'identity_authority', 'core_server_v1'),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES(
    p_idempotency_key, 'create_production', f, result, auth.uid()
  );

  RETURN result;
END
$$;

CREATE OR REPLACE FUNCTION public.trace_sign_handover_evidence_v1(
  p_stage text,
  p_entity_type text,
  p_entity_id text,
  p_reference_no text,
  p_metadata jsonb,
  p_actor_id uuid DEFAULT NULL,
  p_prior_hash text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_stage text := lower(btrim(coalesce(p_stage, '')));
  v_actor uuid := auth.uid();
  v_action text;
  v_key_version integer;
  v_secret bytea;
  v_occurred_at text;
  v_metadata jsonb;
  v_content jsonb;
  v_content_hash text;
  v_chain_hash text;
  v_prior_hash text := coalesce(nullif(btrim(p_prior_hash), ''), 'origin');
BEGIN
  CASE v_stage
    WHEN 'production' THEN v_action := 'production';
    WHEN 'packing'    THEN v_action := 'packing';
    WHEN 'dispatch'   THEN v_action := 'dispatch';
    WHEN 'gate'       THEN v_action := 'dispatch';
    WHEN 'finance'    THEN v_action := 'finance';
    ELSE
      RAISE EXCEPTION 'TRACE_HANDOVER_STAGE_INVALID: %', p_stage USING ERRCODE = '22023';
  END CASE;

  PERFORM public.trace_assert_role_v1(v_action);
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED' USING ERRCODE = 'P0001';
  END IF;
  IF p_actor_id IS NOT NULL AND p_actor_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_ACTOR_MISMATCH' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_entity_type), '') IS NULL
     OR nullif(btrim(p_entity_id), '') IS NULL
     OR nullif(btrim(p_reference_no), '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_IDENTITY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  SELECT key_version, secret
    INTO v_key_version, v_secret
    FROM public.ols_trace_handover_signing_keys
   WHERE active
   ORDER BY key_version DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_SIGNING_KEY_MISSING' USING ERRCODE = '55000';
  END IF;

  v_occurred_at := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_metadata := coalesce(p_metadata, '{}'::jsonb)
    || jsonb_build_object(
      '_core_key_version', v_key_version,
      '_core_prior_hash', v_prior_hash
    );

  v_content := jsonb_build_object(
    'version', '1.0',
    'integrityClass', 'core_signed_v1',
    'stage', v_stage,
    'entityType', btrim(p_entity_type),
    'entityId', btrim(p_entity_id),
    'referenceNo', btrim(p_reference_no),
    'actorId', v_actor::text,
    'occurredAt', v_occurred_at,
    'metadata', v_metadata
  );

  v_content_hash := encode(extensions.digest(convert_to(v_content::text, 'UTF8'), 'sha256'), 'hex');
  v_chain_hash := encode(
    extensions.hmac(
      convert_to(v_prior_hash || '|' || v_content_hash, 'UTF8'),
      v_secret,
      'sha256'
    ),
    'hex'
  );

  RETURN v_content || jsonb_build_object(
    'contentHash', v_content_hash,
    'chainHash', v_chain_hash
  );
END
$$;

CREATE OR REPLACE FUNCTION public.trace_handover_expected_stage_v1(p_action text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_action, ''))) LIKE 'trace_production%' THEN 'production'
    WHEN lower(btrim(coalesce(p_action, ''))) LIKE 'trace_carton%'
      OR lower(btrim(coalesce(p_action, ''))) LIKE 'trace_packing%' THEN 'packing'
    WHEN lower(btrim(coalesce(p_action, ''))) LIKE 'trace_dispatch%'
      OR lower(btrim(coalesce(p_action, ''))) LIKE 'trace_dpl%'
      OR lower(btrim(coalesce(p_action, ''))) LIKE 'trace_gate%' THEN 'dispatch'
    WHEN lower(btrim(coalesce(p_action, ''))) LIKE 'trace_finance%'
      OR lower(btrim(coalesce(p_action, ''))) LIKE 'trace_pi%' THEN 'finance'
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public.trace_handover_expected_stage_v1(text) FROM PUBLIC, anon;

DROP FUNCTION IF EXISTS public.trace_verify_handover_evidence_v1(jsonb, text);

CREATE OR REPLACE FUNCTION public.trace_verify_handover_evidence_v1(
  p_evidence jsonb,
  p_prior_hash text DEFAULT NULL,
  p_expected_action text DEFAULT NULL,
  p_enforce_consumption boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_key_version integer;
  v_secret bytea;
  v_prior_hash text;
  v_content jsonb;
  v_content_hash text;
  v_expected_chain_hash text;
  v_expected_stage text;
  v_occurred_at timestamptz;
  v_validity_window constant interval := interval '15 minutes';
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_VERIFY_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL
     OR p_evidence->>'integrityClass' <> 'core_signed_v1'
     OR p_evidence->>'version' <> '1.0'
     OR nullif(p_evidence->>'actorId', '') IS NULL
     OR nullif(p_evidence->>'occurredAt', '') IS NULL
     OR nullif(p_evidence->>'contentHash', '') IS NULL
     OR nullif(p_evidence->>'chainHash', '') IS NULL THEN
    RETURN false;
  END IF;

  IF p_enforce_consumption THEN
    IF nullif(btrim(p_expected_action), '') IS NULL THEN
      RETURN false;
    END IF;

    v_expected_stage := public.trace_handover_expected_stage_v1(p_expected_action);
    IF v_expected_stage IS NULL
       OR lower(p_evidence->>'stage') IS DISTINCT FROM lower(v_expected_stage) THEN
      RETURN false;
    END IF;

    BEGIN
      v_occurred_at := (p_evidence->>'occurredAt')::timestamptz;
    EXCEPTION WHEN others THEN
      RETURN false;
    END;

    IF v_occurred_at < (now() - v_validity_window)
       OR v_occurred_at > (now() + interval '1 minute') THEN
      RETURN false;
    END IF;

    IF EXISTS (
      SELECT 1
        FROM public.ols_audit_logs
       WHERE lower(coalesce(details->'handover_evidence'->>'contentHash', ''))
               = lower(p_evidence->>'contentHash')
    ) THEN
      RETURN false;
    END IF;
  END IF;

  BEGIN
    v_key_version := (p_evidence#>>'{metadata,_core_key_version}')::integer;
  EXCEPTION WHEN others THEN
    RETURN false;
  END;

  SELECT secret INTO v_secret
    FROM public.ols_trace_handover_signing_keys
   WHERE key_version = v_key_version;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_prior_hash := coalesce(
    nullif(btrim(p_prior_hash), ''),
    nullif(p_evidence#>>'{metadata,_core_prior_hash}', ''),
    'origin'
  );

  v_content := jsonb_build_object(
    'version', p_evidence->>'version',
    'integrityClass', p_evidence->>'integrityClass',
    'stage', p_evidence->>'stage',
    'entityType', p_evidence->>'entityType',
    'entityId', p_evidence->>'entityId',
    'referenceNo', p_evidence->>'referenceNo',
    'actorId', p_evidence->>'actorId',
    'occurredAt', p_evidence->>'occurredAt',
    'metadata', coalesce(p_evidence->'metadata', '{}'::jsonb)
  );

  v_content_hash := encode(extensions.digest(convert_to(v_content::text, 'UTF8'), 'sha256'), 'hex');
  IF lower(v_content_hash) IS DISTINCT FROM lower(p_evidence->>'contentHash') THEN
    RETURN false;
  END IF;

  v_expected_chain_hash := encode(
    extensions.hmac(
      convert_to(v_prior_hash || '|' || v_content_hash, 'UTF8'),
      v_secret,
      'sha256'
    ),
    'hex'
  );

  RETURN lower(v_expected_chain_hash) = lower(p_evidence->>'chainHash');
END
$$;

CREATE OR REPLACE FUNCTION public.trace_insert_handover_audit_v1(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_details jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_existing public.ols_audit_logs;
  v_inserted public.ols_audit_logs;
  v_evidence jsonb := p_details->'handover_evidence';
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_AUDIT_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_IDEMPOTENCY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));

  SELECT * INTO v_existing
    FROM public.ols_audit_logs
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.entity_id IS DISTINCT FROM p_entity_id
       OR v_existing.entity_type IS DISTINCT FROM p_entity_type THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN to_jsonb(v_existing);
  END IF;

  IF NOT public.trace_verify_handover_evidence_v1(v_evidence, NULL, p_action, true) THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_EVIDENCE_INVALID' USING ERRCODE = '22023';
  END IF;
  IF v_evidence->>'actorId' IS DISTINCT FROM v_actor::text
     OR v_evidence->>'entityId' IS DISTINCT FROM p_entity_id::text
     OR v_evidence->>'entityType' IS DISTINCT FROM p_entity_type THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_EVIDENCE_BINDING_MISMATCH' USING ERRCODE = '42501';
  END IF;

  BEGIN
    INSERT INTO public.ols_audit_logs(
      action, entity_type, entity_id, user_id, details, idempotency_key
    ) VALUES(
      p_action,
      p_entity_type,
      p_entity_id,
      v_actor,
      coalesce(p_details, '{}'::jsonb) || jsonb_build_object('idempotency_key', p_idempotency_key),
      p_idempotency_key
    )
    RETURNING * INTO v_inserted;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT * INTO v_existing
        FROM public.ols_audit_logs
       WHERE idempotency_key = p_idempotency_key;
      IF NOT FOUND THEN
        RAISE;
      END IF;
      IF v_existing.entity_id IS DISTINCT FROM p_entity_id
         OR v_existing.entity_type IS DISTINCT FROM p_entity_type THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
      END IF;
      RETURN to_jsonb(v_existing);
  END;

  RETURN to_jsonb(v_inserted);
END
$$;

-- New authenticated overload consumed by current oasis-trace. The old five-argument
-- overload remains for service-role compatibility only and is revoked from authenticated.
CREATE OR REPLACE FUNCTION public.trace_finalize_carton_v1(
  p_carton_id uuid,
  p_net_weight numeric,
  p_gross_weight numeric,
  p_copied_to_clipboard boolean,
  p_idempotency_key text,
  p_handover_evidence jsonb,
  p_actor_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  f text := md5(jsonb_build_array(p_carton_id, p_net_weight, p_gross_weight, p_copied_to_clipboard)::text);
  prior record;
  c public.ols_cartons;
  result jsonb;
  v_actor uuid := auth.uid();
BEGIN
  PERFORM public.trace_assert_role_v1('packing');
  IF nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'INVALID_TRACE_MUTATION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  SELECT payload_fingerprint, response
    INTO prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.payload_fingerprint <> f THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN prior.response;
  END IF;

  IF p_actor_id IS NOT NULL AND p_actor_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_ACTOR_MISMATCH' USING ERRCODE = '42501';
  END IF;
  IF NOT public.trace_verify_handover_evidence_v1(
       p_handover_evidence, NULL, 'trace_carton_finalized', true
     ) THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_EVIDENCE_INVALID' USING ERRCODE = '22023';
  END IF;
  IF p_handover_evidence->>'integrityClass' <> 'core_signed_v1'
     OR p_handover_evidence->>'stage' <> 'packing'
     OR p_handover_evidence->>'entityType' <> 'carton'
     OR p_handover_evidence->>'entityId' <> p_carton_id::text
     OR p_handover_evidence->>'actorId' <> v_actor::text THEN
    RAISE EXCEPTION 'TRACE_HANDOVER_EVIDENCE_BINDING_MISMATCH' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO c
    FROM public.ols_cartons
   WHERE id = p_carton_id
   FOR UPDATE;
  IF NOT FOUND
     OR c.status <> 'draft'
     OR NOT EXISTS(SELECT 1 FROM public.ols_carton_contents WHERE carton_id = c.id) THEN
    RAISE EXCEPTION 'CARTON_NOT_FINALIZABLE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.ols_cartons
     SET status = 'packed',
         packed_at = now(),
         packed_by = v_actor,
         net_weight = p_net_weight,
         gross_weight = p_gross_weight
   WHERE id = c.id
   RETURNING * INTO c;

  INSERT INTO public.ols_print_logs(
    ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason
  ) VALUES(
    'carton', c.id, v_actor, true, false, 0,
    CASE WHEN p_copied_to_clipboard
      THEN 'command_generated_clipboard_copied'
      ELSE 'command_generated_clipboard_unavailable'
    END
  );

  result := to_jsonb(c);

  INSERT INTO public.ols_audit_logs(
    action, entity_type, entity_id, user_id, details, idempotency_key
  ) VALUES(
    'trace_carton_finalized',
    'carton',
    c.id,
    v_actor,
    jsonb_build_object(
      'handover_evidence', p_handover_evidence,
      'idempotency_key', p_idempotency_key,
      'authority', 'core_signed_v1'
    ),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES(
    p_idempotency_key, 'finalize_carton', f, result, v_actor
  );

  RETURN result;
END
$$;

REVOKE ALL ON FUNCTION public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text,jsonb,uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text,jsonb,uuid) TO authenticated, service_role;

-- Authenticated clients must use the evidence-bearing overload; keep the legacy
-- five-argument form only for controlled service-role compatibility.
REVOKE EXECUTE ON FUNCTION public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text) TO service_role;
