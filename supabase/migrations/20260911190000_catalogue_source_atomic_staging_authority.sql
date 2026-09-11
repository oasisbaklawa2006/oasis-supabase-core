-- Issue #282: CATALOGUE SOURCE — atomic batch+entries+status+audit staging RPC.
--
-- Census finding: 20260910160000/100/200 deployed catalogue_source_batches,
-- catalogue_source_entries and catalogue_source_audit_log with direct
-- authenticated-staff RLS INSERT/UPDATE policies only. No RPC exists. AI
-- Studio's client therefore performs batch create, entry upsert, status
-- transition and audit insert as separate requests -- a client-side
-- pseudo-transaction with no atomicity across a partial failure. This
-- migration adds the single governed entrypoint that performs all four
-- sub-steps as one Postgres function invocation (one implicit transaction:
-- any RAISE EXCEPTION unwinds every write made inside the function).
--
-- Boundary preserved from #276: this function never touches public.products,
-- never sets a price, never publishes, and never activates anything. It only
-- ever writes to catalogue_source_batches / catalogue_source_entries /
-- catalogue_source_audit_log.

CREATE OR REPLACE FUNCTION public.stage_catalogue_source_entry(
  p_dedupe_key text,
  p_source_provider text,
  p_source_document_name text,
  p_source_entry_key text,
  p_source_document_id text DEFAULT NULL,
  p_source_revision text DEFAULT NULL,
  p_source_hash text DEFAULT NULL,
  p_source_metadata jsonb DEFAULT '{}'::jsonb,
  p_source_page_number integer DEFAULT NULL,
  p_source_title text DEFAULT NULL,
  p_source_sku text DEFAULT NULL,
  p_source_slug text DEFAULT NULL,
  p_raw_source_data jsonb DEFAULT '{}'::jsonb,
  p_candidate_product_data jsonb DEFAULT '{}'::jsonb,
  p_target_batch_status text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  batch_status text,
  batch_dedupe_key text,
  entry_id uuid,
  entry_status text,
  entry_was_replayed boolean,
  audit_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_batch public.catalogue_source_batches%ROWTYPE;
  v_entry public.catalogue_source_entries%ROWTYPE;
  v_existing_entry public.catalogue_source_entries%ROWTYPE;
  v_from_batch_status text;
  v_to_batch_status text;
  v_entry_replayed boolean := false;
  v_audit_id uuid;
  v_now timestamptz := now();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_team_member(v_actor_id) THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_UNAUTHORIZED' USING ERRCODE = '42501';
  END IF;

  IF nullif(btrim(coalesce(p_dedupe_key, '')), '') IS NULL THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_DEDUPE_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_source_provider, '')), '') IS NULL THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_PROVIDER_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_source_document_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_DOCUMENT_NAME_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_source_entry_key, '')), '') IS NULL THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_ENTRY_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF p_target_batch_status IS NOT NULL
     AND p_target_batch_status NOT IN ('RECEIVED', 'PARSING', 'READY_FOR_REVIEW') THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_TARGET_STATUS_NOT_STAGEABLE' USING ERRCODE = '22023';
  END IF;

  -- Serialize every staging call for this source document on one advisory
  -- lock so batch create-or-replay, entry create-or-replay and the batch
  -- status transition all observe a consistent snapshot even when two
  -- concurrent callers race the same dedupe_key.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('catalogue_source_staging:' || p_dedupe_key, 0)
  );

  SELECT * INTO v_batch
  FROM public.catalogue_source_batches
  WHERE dedupe_key = p_dedupe_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_batch.source_provider IS DISTINCT FROM p_source_provider
       OR v_batch.source_document_name IS DISTINCT FROM p_source_document_name
       OR v_batch.source_document_id IS DISTINCT FROM p_source_document_id
       OR v_batch.source_revision IS DISTINCT FROM p_source_revision
       OR v_batch.source_hash IS DISTINCT FROM p_source_hash
       OR v_batch.source_metadata IS DISTINCT FROM coalesce(p_source_metadata, '{}'::jsonb) THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_BATCH_REPLAY_MISMATCH'
        USING ERRCODE = '40001',
              DETAIL = format('dedupe_key %s already identifies a different source document/revision; use a new dedupe_key for a governed new revision', p_dedupe_key);
    END IF;
  ELSE
    INSERT INTO public.catalogue_source_batches (
      source_provider, source_document_id, source_document_name, source_revision,
      source_hash, dedupe_key, status, source_metadata, imported_by
    ) VALUES (
      p_source_provider, p_source_document_id, p_source_document_name, p_source_revision,
      p_source_hash, p_dedupe_key, 'RECEIVED', coalesce(p_source_metadata, '{}'::jsonb), v_actor_id
    )
    RETURNING * INTO v_batch;
  END IF;

  v_from_batch_status := v_batch.status;

  -- Resolve the entry BEFORE the terminal-batch check: an exact replay of an
  -- entry that already exists must still return existing durable state even
  -- on a REVIEWED/ARCHIVED/FAILED batch (idempotent replay is always safe --
  -- it changes nothing). Only a genuinely NEW entry is blocked from landing
  -- on a terminal batch.
  SELECT * INTO v_existing_entry
  FROM public.catalogue_source_entries AS cse
  WHERE cse.batch_id = v_batch.id AND cse.source_entry_key = p_source_entry_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_entry.raw_source_data IS DISTINCT FROM coalesce(p_raw_source_data, '{}'::jsonb)
       OR v_existing_entry.candidate_product_data IS DISTINCT FROM coalesce(p_candidate_product_data, '{}'::jsonb)
       OR v_existing_entry.source_title IS DISTINCT FROM p_source_title
       OR v_existing_entry.source_sku IS DISTINCT FROM p_source_sku
       OR v_existing_entry.source_slug IS DISTINCT FROM p_source_slug
       OR v_existing_entry.source_page_number IS DISTINCT FROM p_source_page_number THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_ENTRY_REPLAY_MISMATCH'
        USING ERRCODE = '40001',
              DETAIL = format('entry %s in batch %s already holds different content; use a new source_entry_key for a governed new revision', p_source_entry_key, v_batch.id);
    END IF;
    v_entry := v_existing_entry;
    v_entry_replayed := true;
  ELSE
    IF v_batch.status IN ('REVIEWED', 'ARCHIVED', 'FAILED') THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_BATCH_TERMINAL'
        USING ERRCODE = '40001',
              DETAIL = format('batch %s is %s and cannot acquire new staged entries', v_batch.id, v_batch.status);
    END IF;
    INSERT INTO public.catalogue_source_entries (
      batch_id, source_entry_key, source_page_number, source_title, source_sku, source_slug,
      raw_source_data, candidate_product_data, status
    ) VALUES (
      v_batch.id, p_source_entry_key, p_source_page_number, p_source_title, p_source_sku, p_source_slug,
      coalesce(p_raw_source_data, '{}'::jsonb), coalesce(p_candidate_product_data, '{}'::jsonb), 'STAGED'
    )
    RETURNING * INTO v_entry;
  END IF;

  v_to_batch_status := coalesce(
    p_target_batch_status,
    CASE WHEN v_from_batch_status = 'RECEIVED' THEN 'PARSING' ELSE v_from_batch_status END
  );

  IF v_to_batch_status <> v_from_batch_status THEN
    IF NOT (
      (v_from_batch_status = 'RECEIVED' AND v_to_batch_status IN ('PARSING', 'READY_FOR_REVIEW'))
      OR (v_from_batch_status = 'PARSING' AND v_to_batch_status = 'READY_FOR_REVIEW')
    ) THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_STAGING_BATCH_TRANSITION_DENIED'
        USING ERRCODE = '40001',
              DETAIL = format('%s -> %s is not a permitted staging transition', v_from_batch_status, v_to_batch_status);
    END IF;
    UPDATE public.catalogue_source_batches
    SET status = v_to_batch_status, updated_at = v_now
    WHERE id = v_batch.id
    RETURNING * INTO v_batch;
  END IF;

  -- Append-only audit event. Skipped only on a fully idempotent no-op replay
  -- (existing batch, existing identical entry, no status change) so retries
  -- of the exact same call do not spam duplicate history; any real write
  -- above always reaches this insert, and a failure here rolls back every
  -- write already made in this invocation.
  IF NOT (v_entry_replayed AND v_to_batch_status = v_from_batch_status) THEN
    INSERT INTO public.catalogue_source_audit_log (
      batch_id, entry_id, action, from_status, to_status, actor_id, metadata
    ) VALUES (
      v_batch.id, v_entry.id, 'catalogue_source_entry_staged', v_from_batch_status, v_to_batch_status, v_actor_id,
      jsonb_build_object(
        'dedupe_key', p_dedupe_key,
        'entry_key', p_source_entry_key,
        'entry_replayed', v_entry_replayed
      )
    )
    RETURNING id INTO v_audit_id;
  END IF;

  RETURN QUERY SELECT v_batch.id, v_batch.status, v_batch.dedupe_key, v_entry.id, v_entry.status, v_entry_replayed, v_audit_id;
END;
$$;

COMMENT ON FUNCTION public.stage_catalogue_source_entry IS
  'Issue #282: atomic batch create/replay + entry persistence + permitted batch status transition + mandatory audit event as one transaction. No public.products mutation, no price/publication/activation authority. Terminal batches (REVIEWED/ARCHIVED/FAILED) reject new entries. Exact replay returns existing durable state; mismatched replay fails closed.';

REVOKE ALL ON FUNCTION public.stage_catalogue_source_entry FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.stage_catalogue_source_entry TO authenticated, service_role;
