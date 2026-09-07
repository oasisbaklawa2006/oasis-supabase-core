-- MACRO-FINANCE A2: bank/settlement reconciliation authority.
-- Immutable source ingestion, deterministic auto-match, governed Finance queue
-- for unmatched/ambiguous cases. Reuses canonical order_payments/adjustments/gateway
-- truth; no duplicate general ledger.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE TABLE IF NOT EXISTS public.bank_settlement_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_channel text NOT NULL CHECK (source_channel IN ('file','api','manual')),
  source_reference text NOT NULL,
  row_count integer NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  imported_by uuid NOT NULL REFERENCES auth.users(id),
  imported_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.bank_settlement_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.bank_settlement_import_batches(id),
  company_id uuid REFERENCES public.companies(id),
  transaction_date date NOT NULL,
  value_date date,
  direction text NOT NULL CHECK (direction IN ('credit','debit')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
  bank_reference text,
  utr text,
  provider_reference text,
  normalized_fingerprint text NOT NULL,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  match_status text NOT NULL DEFAULT 'unmatched'
    CHECK (match_status IN ('unmatched','auto_matched','manual_matched','excluded','duplicate')),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (normalized_fingerprint)
);
CREATE INDEX IF NOT EXISTS bank_settlement_transactions_utr_idx
  ON public.bank_settlement_transactions(lower(btrim(utr))) WHERE utr IS NOT NULL;
CREATE INDEX IF NOT EXISTS bank_settlement_transactions_status_idx
  ON public.bank_settlement_transactions(match_status, transaction_date DESC);

CREATE TABLE IF NOT EXISTS public.bank_reconciliation_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES public.bank_settlement_transactions(id),
  match_target_type text NOT NULL CHECK (match_target_type IN ('order_payment','commercial_adjustment','gateway_intent')),
  match_target_id uuid NOT NULL,
  confidence text NOT NULL CHECK (confidence IN ('exact','high','medium')),
  match_rule text NOT NULL,
  matched_by uuid NOT NULL REFERENCES auth.users(id),
  matched_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE UNIQUE INDEX IF NOT EXISTS bank_reconciliation_matches_transaction_uidx
  ON public.bank_reconciliation_matches(transaction_id);
CREATE UNIQUE INDEX IF NOT EXISTS bank_reconciliation_matches_target_uidx
  ON public.bank_reconciliation_matches(match_target_type, match_target_id);

CREATE TABLE IF NOT EXISTS public.bank_reconciliation_cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid REFERENCES public.bank_settlement_transactions(id),
  company_id uuid REFERENCES public.companies(id),
  case_type text NOT NULL CHECK (case_type IN (
    'unmatched','duplicate','short','excess','refund','chargeback','fee','ambiguous'
  )),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','rejected')),
  amount_delta numeric(14,2),
  reason text NOT NULL,
  opened_by uuid NOT NULL REFERENCES auth.users(id),
  opened_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.bank_reconciliation_case_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES public.bank_reconciliation_cases(id),
  event_type text NOT NULL CHECK (event_type IN ('OPENED','MATCHED','UNMATCHED','RESOLVED','REJECTED')),
  notes text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.bank_reconciliation_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL,
  request_fingerprint text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

ALTER TABLE public.bank_settlement_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_settlement_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_reconciliation_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_reconciliation_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_reconciliation_case_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_reconciliation_idempotency ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.bank_settlement_import_batches,
  public.bank_settlement_transactions,
  public.bank_reconciliation_matches,
  public.bank_reconciliation_cases,
  public.bank_reconciliation_case_events,
  public.bank_reconciliation_idempotency
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.bank_settlement_import_batches,
  public.bank_settlement_transactions,
  public.bank_reconciliation_matches,
  public.bank_reconciliation_cases,
  public.bank_reconciliation_case_events
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_bank_reconciliation_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'BANK_RECONCILIATION_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_bank_reconciliation_matches_immutable ON public.bank_reconciliation_matches;
CREATE TRIGGER trg_bank_reconciliation_matches_immutable
  BEFORE UPDATE OR DELETE ON public.bank_reconciliation_matches
  FOR EACH ROW EXECUTE FUNCTION public.prevent_bank_reconciliation_mutation();
DROP TRIGGER IF EXISTS trg_bank_reconciliation_case_events_immutable ON public.bank_reconciliation_case_events;
CREATE TRIGGER trg_bank_reconciliation_case_events_immutable
  BEFORE UPDATE OR DELETE ON public.bank_reconciliation_case_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_bank_reconciliation_mutation();
REVOKE ALL ON FUNCTION public.prevent_bank_reconciliation_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.import_bank_settlement_batch_v1(
  p_source_channel text,
  p_source_reference text,
  p_rows jsonb,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(batch_id uuid, imported_count integer, already_imported boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_channel text := lower(btrim(coalesce(p_source_channel, '')));
  v_existing public.bank_reconciliation_idempotency%rowtype;
  v_batch public.bank_settlement_import_batches%rowtype;
  v_row jsonb;
  v_count integer := 0;
  v_fingerprint text;
  v_tx_fingerprint text;
  v_response jsonb;
  v_inserted integer;
  v_existing_tx uuid;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF v_channel NOT IN ('file','api','manual')
     OR nullif(btrim(p_source_reference), '') IS NULL
     OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array'
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'BANK_SETTLEMENT_IMPORT_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'source_channel', v_channel, 'source_reference', btrim(p_source_reference),
    'row_count', jsonb_array_length(p_rows), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.bank_reconciliation_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'BANK_SETTLEMENT_IMPORT_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response ->> 'batch_id')::uuid,
      (v_existing.response ->> 'imported_count')::integer,
      true;
    RETURN;
  END IF;
  INSERT INTO public.bank_settlement_import_batches(
    source_channel, source_reference, row_count, imported_by, imported_role, correlation_id, idempotency_key
  ) VALUES (
    v_channel, btrim(p_source_reference), jsonb_array_length(p_rows), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_batch;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    IF nullif(v_row ->> 'transaction_date', '') IS NULL
       OR nullif(v_row ->> 'direction', '') IS NULL
       OR (v_row ->> 'amount') IS NULL
       OR (v_row ->> 'amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'BANK_SETTLEMENT_ROW_INVALID' USING ERRCODE = 'P0001';
    END IF;
    v_tx_fingerprint := encode(extensions.digest(jsonb_build_object(
      'transaction_date', v_row ->> 'transaction_date',
      'direction', lower(v_row ->> 'direction'),
      'amount', round((v_row ->> 'amount')::numeric, 2)::text,
      'currency', upper(coalesce(nullif(v_row ->> 'currency', ''), 'INR')),
      'utr', coalesce(nullif(btrim(v_row ->> 'utr'), ''), ''),
      'bank_reference', coalesce(nullif(btrim(v_row ->> 'bank_reference'), ''), '')
    )::text, 'sha256'), 'hex');
    INSERT INTO public.bank_settlement_transactions(
      batch_id, company_id, transaction_date, value_date, direction, amount, currency,
      bank_reference, utr, provider_reference, normalized_fingerprint, raw_payload
    ) VALUES (
      v_batch.id, nullif(v_row ->> 'company_id', '')::uuid,
      (v_row ->> 'transaction_date')::date,
      nullif(v_row ->> 'value_date', '')::date,
      lower(v_row ->> 'direction'),
      round((v_row ->> 'amount')::numeric, 2),
      upper(coalesce(nullif(v_row ->> 'currency', ''), 'INR')),
      nullif(btrim(v_row ->> 'bank_reference'), ''),
      nullif(btrim(v_row ->> 'utr'), ''),
      nullif(btrim(v_row ->> 'provider_reference'), ''),
      v_tx_fingerprint,
      coalesce(v_row -> 'raw_payload', v_row)
    ) ON CONFLICT (normalized_fingerprint) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted = 0 THEN
      SELECT t.id INTO v_existing_tx
        FROM public.bank_settlement_transactions t
       WHERE t.normalized_fingerprint = v_tx_fingerprint
       LIMIT 1;
      IF v_existing_tx IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.bank_reconciliation_cases c
         WHERE c.transaction_id = v_existing_tx AND c.case_type = 'duplicate' AND c.status = 'open'
      ) THEN
        INSERT INTO public.bank_reconciliation_cases(
          transaction_id, company_id, case_type, status, amount_delta, reason,
          opened_by, opened_role, correlation_id, idempotency_key
        ) VALUES (
          v_existing_tx, nullif(v_row ->> 'company_id', '')::uuid, 'duplicate', 'open', NULL,
          'Duplicate bank settlement transaction fingerprint detected across batches',
          v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':dup:' || v_tx_fingerprint
        );
        INSERT INTO public.bank_reconciliation_case_events(
          case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
        )
        SELECT c.id, 'OPENED', c.reason, v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':dup-event:' || c.id::text
          FROM public.bank_reconciliation_cases c
         WHERE c.idempotency_key = btrim(p_idempotency_key) || ':dup:' || v_tx_fingerprint;
      END IF;
      CONTINUE;
    END IF;
    IF v_inserted > 0 THEN v_count := v_count + 1; END IF;
  END LOOP;
  UPDATE public.bank_settlement_import_batches SET row_count = v_count WHERE id = v_batch.id;
  v_response := jsonb_build_object('batch_id', v_batch.id, 'imported_count', v_count);
  INSERT INTO public.bank_reconciliation_idempotency(idempotency_key, operation, request_fingerprint, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'IMPORT_BATCH', v_fingerprint, v_actor, v_response);
  RETURN QUERY SELECT v_batch.id, v_count, false;
END;
$$;
REVOKE ALL ON FUNCTION public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.auto_match_bank_settlement_batch_v1(
  p_batch_id uuid,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(matched_count integer, unmatched_count integer, ambiguous_count integer, already_matched boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_existing public.bank_reconciliation_idempotency%rowtype;
  v_tx public.bank_settlement_transactions%rowtype;
  v_payment public.order_payments%rowtype;
  v_matched integer := 0;
  v_unmatched integer := 0;
  v_ambiguous integer := 0;
  v_hits integer;
  v_fingerprint text;
  v_response jsonb;
  v_match_rule text;
  v_match_source text;
  v_amount_delta numeric;
  v_case_type text;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'BANK_RECONCILIATION_MATCH_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.bank_settlement_import_batches b WHERE b.id = p_batch_id) THEN
    RAISE EXCEPTION 'BANK_SETTLEMENT_BATCH_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'batch_id', p_batch_id, 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.bank_reconciliation_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'BANK_RECONCILIATION_MATCH_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response ->> 'matched_count')::integer,
      (v_existing.response ->> 'unmatched_count')::integer,
      (v_existing.response ->> 'ambiguous_count')::integer,
      true;
    RETURN;
  END IF;
  FOR v_tx IN
    SELECT * FROM public.bank_settlement_transactions t
     WHERE t.batch_id = p_batch_id AND t.match_status = 'unmatched'
     FOR UPDATE
  LOOP
    v_hits := 0;
    v_payment := NULL;
    v_match_rule := NULL;
    v_match_source := NULL;
    IF v_tx.direction <> 'credit' THEN
      INSERT INTO public.bank_reconciliation_cases(
        transaction_id, company_id, case_type, status, amount_delta, reason,
        opened_by, opened_role, correlation_id, idempotency_key
      ) VALUES (
        v_tx.id, v_tx.company_id,
        CASE v_tx.direction WHEN 'debit' THEN 'fee' ELSE 'unmatched' END,
        'open', NULL,
        'Non-receipt bank line requires governed Finance review before canonical matching',
        v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':noncredit:' || v_tx.id::text
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      INSERT INTO public.bank_reconciliation_case_events(
        case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
      )
      SELECT c.id, 'OPENED', c.reason, v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':noncredit-event:' || c.id::text
        FROM public.bank_reconciliation_cases c
       WHERE c.idempotency_key = btrim(p_idempotency_key) || ':noncredit:' || v_tx.id::text;
      v_unmatched := v_unmatched + 1;
      CONTINUE;
    END IF;
    IF v_tx.utr IS NOT NULL THEN
      SELECT count(*) INTO v_hits
        FROM public.order_payments p
       WHERE lower(btrim(p.reference_no)) = lower(btrim(v_tx.utr))
         AND (v_tx.company_id IS NULL OR p.company_id = v_tx.company_id)
         AND coalesce(p.currency, 'INR') = v_tx.currency
         AND coalesce(p.status, '') IN ('uploaded','verified');
      IF v_hits = 1 THEN
        v_match_source := 'utr';
        v_match_rule := 'UTR_EXACT';
        SELECT * INTO v_payment FROM public.order_payments p
         WHERE lower(btrim(p.reference_no)) = lower(btrim(v_tx.utr))
           AND (v_tx.company_id IS NULL OR p.company_id = v_tx.company_id)
           AND coalesce(p.currency, 'INR') = v_tx.currency
           AND coalesce(p.status, '') IN ('uploaded','verified')
         LIMIT 1;
      END IF;
    END IF;
    IF v_hits = 0 AND v_tx.bank_reference IS NOT NULL THEN
      SELECT count(*) INTO v_hits
        FROM public.order_payments p
       WHERE lower(btrim(p.reference_no)) = lower(btrim(v_tx.bank_reference))
         AND (v_tx.company_id IS NULL OR p.company_id = v_tx.company_id)
         AND coalesce(p.currency, 'INR') = v_tx.currency
         AND coalesce(p.status, '') IN ('uploaded','verified');
      IF v_hits = 1 THEN
        v_match_source := 'bank_reference';
        v_match_rule := 'BANK_REFERENCE_EXACT';
        SELECT * INTO v_payment FROM public.order_payments p
         WHERE lower(btrim(p.reference_no)) = lower(btrim(v_tx.bank_reference))
           AND (v_tx.company_id IS NULL OR p.company_id = v_tx.company_id)
           AND coalesce(p.currency, 'INR') = v_tx.currency
           AND coalesce(p.status, '') IN ('uploaded','verified')
         LIMIT 1;
      END IF;
    END IF;
    IF v_hits = 1 AND v_payment.id IS NOT NULL
       AND abs(v_tx.amount - coalesce(v_payment.verified_amount, v_payment.amount)) <= 0.01 THEN
      BEGIN
        INSERT INTO public.bank_reconciliation_matches(
          transaction_id, match_target_type, match_target_id, confidence, match_rule,
          matched_by, matched_role, correlation_id, idempotency_key
        ) VALUES (
          v_tx.id, 'order_payment', v_payment.id, 'exact', v_match_rule,
          v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':' || v_tx.id::text
        );
        UPDATE public.bank_settlement_transactions SET match_status = 'auto_matched' WHERE id = v_tx.id;
        v_matched := v_matched + 1;
      EXCEPTION WHEN unique_violation THEN
        INSERT INTO public.bank_reconciliation_cases(
          transaction_id, company_id, case_type, status, amount_delta, reason,
          opened_by, opened_role, correlation_id, idempotency_key
        ) VALUES (
          v_tx.id, v_tx.company_id, 'ambiguous', 'open', NULL,
          'Canonical match target or transaction already reconciled',
          v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':unique:' || v_tx.id::text
        ) ON CONFLICT (idempotency_key) DO NOTHING;
        v_ambiguous := v_ambiguous + 1;
      END;
    ELSIF v_hits = 1 AND v_payment.id IS NOT NULL THEN
      v_amount_delta := round(v_tx.amount - coalesce(v_payment.verified_amount, v_payment.amount), 2);
      v_case_type := CASE WHEN v_amount_delta < 0 THEN 'short' ELSE 'excess' END;
      INSERT INTO public.bank_reconciliation_cases(
        transaction_id, company_id, case_type, status, amount_delta, reason,
        opened_by, opened_role, correlation_id, idempotency_key
      ) VALUES (
        v_tx.id, v_tx.company_id, v_case_type, 'open', abs(v_amount_delta),
        format('Single canonical payment candidate via %s differs by %s', coalesce(v_match_source, 'reference'), abs(v_amount_delta)::text),
        v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':' || v_case_type || ':' || v_tx.id::text
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      INSERT INTO public.bank_reconciliation_case_events(
        case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
      )
      SELECT c.id, 'OPENED', c.reason, v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':' || v_case_type || '-event:' || c.id::text
        FROM public.bank_reconciliation_cases c
       WHERE c.idempotency_key = btrim(p_idempotency_key) || ':' || v_case_type || ':' || v_tx.id::text;
      v_unmatched := v_unmatched + 1;
    ELSIF v_hits > 1 THEN
      INSERT INTO public.bank_reconciliation_cases(
        transaction_id, company_id, case_type, status, amount_delta, reason,
        opened_by, opened_role, correlation_id, idempotency_key
      ) VALUES (
        v_tx.id, v_tx.company_id, 'ambiguous', 'open', NULL,
        'Multiple canonical payment candidates for bank transaction',
        v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':case:' || v_tx.id::text
      );
      INSERT INTO public.bank_reconciliation_case_events(
        case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
      )
      SELECT c.id, 'OPENED', c.reason, v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':event:' || c.id::text
        FROM public.bank_reconciliation_cases c
       WHERE c.transaction_id = v_tx.id AND c.idempotency_key = btrim(p_idempotency_key) || ':case:' || v_tx.id::text;
      v_ambiguous := v_ambiguous + 1;
    ELSE
      INSERT INTO public.bank_reconciliation_cases(
        transaction_id, company_id, case_type, status, amount_delta, reason,
        opened_by, opened_role, correlation_id, idempotency_key
      ) VALUES (
        v_tx.id, v_tx.company_id, 'unmatched', 'open', NULL,
        'No deterministic canonical payment match found',
        v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':unmatched:' || v_tx.id::text
      );
      INSERT INTO public.bank_reconciliation_case_events(
        case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
      )
      SELECT c.id, 'OPENED', c.reason, v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':unmatched-event:' || c.id::text
        FROM public.bank_reconciliation_cases c
       WHERE c.idempotency_key = btrim(p_idempotency_key) || ':unmatched:' || v_tx.id::text;
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;
  v_response := jsonb_build_object(
    'matched_count', v_matched, 'unmatched_count', v_unmatched, 'ambiguous_count', v_ambiguous
  );
  INSERT INTO public.bank_reconciliation_idempotency(idempotency_key, operation, request_fingerprint, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'AUTO_MATCH', v_fingerprint, v_actor, v_response);
  RETURN QUERY SELECT v_matched, v_unmatched, v_ambiguous, false;
END;
$$;
REVOKE ALL ON FUNCTION public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_bank_reconciliation_case_v1(
  p_case_id uuid,
  p_resolution text,
  p_match_target_type text,
  p_match_target_id uuid,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(case_id uuid, status text, already_resolved boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_case public.bank_reconciliation_cases%rowtype;
  v_resolution text := upper(btrim(coalesce(p_resolution, '')));
  v_target_type text := lower(btrim(coalesce(p_match_target_type, '')));
  v_existing public.bank_reconciliation_idempotency%rowtype;
  v_fingerprint text;
  v_response jsonb;
  v_sensitive boolean := false;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF v_resolution NOT IN ('MATCH','UNMATCH','RESOLVE','REJECT')
     OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'BANK_RECONCILIATION_RESOLVE_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_case FROM public.bank_reconciliation_cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BANK_RECONCILIATION_CASE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_case.status <> 'open' THEN RAISE EXCEPTION 'BANK_RECONCILIATION_CASE_TERMINAL' USING ERRCODE = '55000'; END IF;
  v_sensitive := v_case.case_type IN ('short','excess','refund','chargeback','ambiguous');
  IF v_sensitive AND v_case.opened_by = v_actor THEN
    RAISE EXCEPTION 'BANK_RECONCILIATION_MAKER_CHECKER' USING ERRCODE = '42501';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'case_id', p_case_id, 'resolution', v_resolution, 'match_target_type', v_target_type,
    'match_target_id', p_match_target_id, 'reason', btrim(p_reason), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.bank_reconciliation_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'BANK_RECONCILIATION_RESOLVE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT p_case_id, v_existing.response ->> 'status', true;
    RETURN;
  END IF;
  IF v_resolution = 'MATCH' THEN
    IF v_target_type NOT IN ('order_payment','commercial_adjustment','gateway_intent') OR p_match_target_id IS NULL THEN
      RAISE EXCEPTION 'BANK_RECONCILIATION_MATCH_TARGET_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      INSERT INTO public.bank_reconciliation_matches(
        transaction_id, match_target_type, match_target_id, confidence, match_rule,
        matched_by, matched_role, correlation_id, idempotency_key
      ) VALUES (
        v_case.transaction_id, v_target_type, p_match_target_id, 'high', 'MANUAL_FINANCE_MATCH',
        v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':match'
      );
      UPDATE public.bank_settlement_transactions SET match_status = 'manual_matched'
       WHERE id = v_case.transaction_id;
      INSERT INTO public.bank_reconciliation_case_events(
        case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
      ) VALUES (
        p_case_id, 'MATCHED', btrim(p_reason), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':matched'
      );
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'BANK_RECONCILIATION_MATCH_TARGET_CONFLICT' USING ERRCODE = '23505';
    END;
  ELSIF v_resolution = 'UNMATCH' THEN
    INSERT INTO public.bank_reconciliation_case_events(
      case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
    ) VALUES (
      p_case_id, 'UNMATCHED', btrim(p_reason), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':unmatched'
    );
  END IF;
  UPDATE public.bank_reconciliation_cases
     SET status = CASE v_resolution WHEN 'REJECT' THEN 'rejected' ELSE 'resolved' END
   WHERE id = p_case_id;
  INSERT INTO public.bank_reconciliation_case_events(
    case_id, event_type, notes, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    p_case_id,
    CASE v_resolution WHEN 'REJECT' THEN 'REJECTED' ELSE 'RESOLVED' END,
    btrim(p_reason), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key) || ':terminal'
  );
  v_response := jsonb_build_object('case_id', p_case_id, 'status', CASE v_resolution WHEN 'REJECT' THEN 'rejected' ELSE 'resolved' END);
  INSERT INTO public.bank_reconciliation_idempotency(idempotency_key, operation, request_fingerprint, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'RESOLVE_CASE', v_fingerprint, v_actor, v_response);
  RETURN QUERY SELECT p_case_id, v_response ->> 'status', false;
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_bank_reconciliation_summary_v1(p_batch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'BANK_RECONCILIATION_SUMMARY_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'batch_filter', p_batch_id,
    'transactions', coalesce((
      SELECT jsonb_build_object(
        'total', count(*),
        'auto_matched', count(*) FILTER (WHERE t.match_status = 'auto_matched'),
        'manual_matched', count(*) FILTER (WHERE t.match_status = 'manual_matched'),
        'unmatched', count(*) FILTER (WHERE t.match_status = 'unmatched'),
        'excluded', count(*) FILTER (WHERE t.match_status = 'excluded')
      )
      FROM public.bank_settlement_transactions t
     WHERE p_batch_id IS NULL OR t.batch_id = p_batch_id
    ), '{}'::jsonb),
    'open_cases', coalesce((
      SELECT count(*) FROM public.bank_reconciliation_cases c
       WHERE c.status = 'open'
         AND (p_batch_id IS NULL OR c.transaction_id IN (
           SELECT t.id FROM public.bank_settlement_transactions t WHERE t.batch_id = p_batch_id
         ))
    ), 0),
    'facts_as_of', statement_timestamp(),
    'reconciliation_summary_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_bank_reconciliation_summary_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_bank_reconciliation_summary_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_bank_reconciliation_tally_projection_v1(p_batch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'BANK_RECONCILIATION_TALLY_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'batch_filter', p_batch_id,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'transaction_id', t.id,
        'transaction_date', t.transaction_date,
        'direction', t.direction,
        'amount', t.amount,
        'currency', t.currency,
        'utr', t.utr,
        'bank_reference', t.bank_reference,
        'match_status', t.match_status,
        'match_target_type', m.match_target_type,
        'match_target_id', m.match_target_id,
        'confidence', m.confidence
      ) ORDER BY t.transaction_date, t.id)
      FROM public.bank_settlement_transactions t
      LEFT JOIN public.bank_reconciliation_matches m ON m.transaction_id = t.id
     WHERE p_batch_id IS NULL OR t.batch_id = p_batch_id
    ), '[]'::jsonb),
    'facts_as_of', statement_timestamp(),
    'tally_projection_only', true,
    'duplicate_gl', false
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_bank_reconciliation_tally_projection_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_bank_reconciliation_tally_projection_v1(uuid) TO authenticated;

COMMENT ON TABLE public.bank_settlement_transactions IS 'A2 normalized bank/settlement lines. Auto-match never silently resolves ambiguous candidates.';
COMMENT ON FUNCTION public.get_bank_reconciliation_tally_projection_v1(uuid) IS 'Accounting-compatible reconciliation projection without creating a duplicate GL.';
