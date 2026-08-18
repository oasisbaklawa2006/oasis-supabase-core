-- Forward-only replacement of supabase/migrations/20260817130000_rgs_quick_log_production_rpc.sql.
-- The original was merged to Core main (PR #83) but never applied to production
-- (tcxvcatsqqertcnycuop) because its historical timestamp sits below the current
-- production ledger max (20260817211610, from an unrelated WhatsApp deploy that
-- landed out of band). Per the Controlled Supabase Production Release runbook,
-- a migration below production max must never be pushed under its original
-- timestamp; this is the same content, forward-timestamped, unmodified.
-- Original: supabase/migrations/20260817130000_rgs_quick_log_production_rpc.sql -- content preserved verbatim below.

-- RGS + Production reconciliation, step 2d: ad-hoc quick-log production.
--
-- Central's PHH QuickEntryTab.tsx logs replenishment-style production that
-- has no pre-existing production_jobs row (it is not routed shortage demand,
-- just a department logging what it made today) and previously wrote
-- daily_production_logs + factory_inventory + production_rgs_transfers
-- directly, all now blocked by the REVOKE in 20260817100000.
--
-- Rather than opening a fourth, parallel write path, quick-log production
-- goes through the SAME governed job lifecycle as routed shortage demand:
-- an ad-hoc production_job is created (order_id NULL, since it is not tied
-- to a specific demand line), output is recorded, the job is declared ready,
-- and it is dispatched to RGS -- all in one atomic call. RGS stock is still
-- only ever posted by accept_rgs_production_receipt once RGS has physically
-- received and accepted it; this RPC never touches inventory_stock_balances
-- or factory_inventory.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.quick_log_production_to_rgs(
  p_product_id uuid,
  p_department text,
  p_produced_qty numeric,
  p_wasted_qty numeric,
  p_correlation_id text,
  p_batch_number text DEFAULT NULL
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_canonical_department text;
  v_job_id uuid;
  v_batch_number text;
  v_transfer public.production_rgs_transfers%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_produced_qty IS NULL OR p_produced_qty <= 0 THEN
    RAISE EXCEPTION 'Produced quantity must be positive';
  END IF;

  -- Idempotent replay: a retried quick-log call with the same correlation id
  -- returns the transfer it already produced.
  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE correlation_id = p_correlation_id;
  IF FOUND THEN RETURN v_transfer; END IF;

  v_canonical_department := public.canonical_production_department(p_department);
  IF v_canonical_department IS NULL THEN
    RAISE EXCEPTION 'Unknown production department %', p_department;
  END IF;
  v_batch_number := coalesce(p_batch_number, 'QLOG-' || to_char(now(), 'YYYYMMDD') || '-' || substr(p_correlation_id, 1, 8));

  INSERT INTO public.production_jobs (
    order_id, product_id, department, requested_by, assigned_qty, priority, status, stage,
    started_at, batch_number, correlation_id
  ) VALUES (
    NULL, p_product_id, v_canonical_department, v_actor_id, p_produced_qty, 'normal', 'in_production', 'processing',
    now(), v_batch_number, p_correlation_id || ':job'
  )
  RETURNING id INTO v_job_id;

  INSERT INTO public.production_job_outputs (job_id, produced_qty, wasted_qty, batch_number, recorded_by, correlation_id)
  VALUES (v_job_id, p_produced_qty, coalesce(p_wasted_qty, 0), v_batch_number, v_actor_id, p_correlation_id || ':output');

  INSERT INTO public.daily_production_logs (product_id, produced_qty, wastage_qty, department, logged_by)
  VALUES (p_product_id, p_produced_qty, coalesce(p_wasted_qty, 0), v_canonical_department, v_actor_id);

  PERFORM public.declare_production_ready(v_job_id, p_correlation_id || ':ready');

  SELECT * INTO v_transfer FROM public.dispatch_production_to_rgs(v_job_id, p_produced_qty, p_correlation_id);

  RETURN v_transfer;
END;
$$;

COMMENT ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) IS
  'Ad-hoc replenishment production with no pre-existing shortage job: creates the job, records output, declares ready and dispatches to RGS in one atomic call, through the same governed lifecycle as routed shortage demand. Never posts to inventory_stock_balances or factory_inventory -- only accept_rgs_production_receipt does that, once RGS has actually received and accepted the goods.';

REVOKE ALL ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) TO authenticated;
