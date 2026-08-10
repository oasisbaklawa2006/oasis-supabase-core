-- Trace (oasis-trace) operational-authority closure.
--
-- Origin: oasis-trace PR #11 forensic audit + CodeRabbit review found that
-- every ols_* table's RLS policy is "to authenticated using(true)" — any
-- authenticated Supabase user, regardless of role, can read/write/close
-- production, dispatch, finance and gate-security records. It also found
-- that DPL <-> carton and Finance PI <-> carton membership was enforced (if
-- at all) only in the Trace frontend, which a direct table write bypasses
-- entirely, and that ols_audit_logs/ols_print_logs had no immutability
-- enforcement at all.
--
-- Owner decision (2026-08-10, Trace PR #11 closure comment) requires:
--   1. Role-scoped RLS — no blanket authenticated write authority.
--   2. Chain-of-custody mutations must be atomic and idempotent; retries
--      must never create duplicate cartons/labels/DPL/PI links/print
--      records/audit events.
--   3. Unlinked/ambiguous DPL or PI carton membership must be rejected
--      (fail closed), never silently accepted.
--
-- This migration closes (1) and (3) for the two flows most directly
-- implicated (DPL creation + membership, Finance PI carton scan +
-- membership) with governed, atomic, idempotent RPCs, and applies a
-- least-privilege "internal staff" floor to every other ols_* write path
-- that is not yet RPC-governed. Finer per-domain authority (production,
-- carton finalization, shipping, gate release) is intentionally deferred —
-- see docs/reconciliation for the tracked follow-up — rather than rushed
-- without staging verification against real Trace user role assignments.

-- =====================================================================
-- 1. Canonical ols_* authority predicates, following the existing
--    can_manage_b2b_dispatch / can_verify_b2b_dispatch_finance pattern.
--    Each includes SUPER_ADMIN/ADMIN as the standard override.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.can_manage_ols_production(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
        'ASSEMBLY_MANAGER', 'PROD_MANAGER', 'PROD_ARABIC', 'PROD_CHOCOLATE',
        'PROD_FUSION', 'PROD_NUTS', 'PROD_DATES', 'PROD_BAKERY',
        'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_DRAGEES',
        'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY'
      ])
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_ols_packing(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PACKING_SUPERVISOR',
        'STORE_INCHARGE', 'STORE_READY_GOODS', 'INVENTORY_MANAGER'
      ])
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_ols_dispatch(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER',
        'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD'
      ])
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_ols_finance(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC'
      ])
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_ols_gate(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'SECURITY_CONTROL', 'GATE_SECURITY',
        'DISPATCH_MANAGER'
      ])
  );
$$;

REVOKE ALL ON FUNCTION public.can_manage_ols_production(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_manage_ols_packing(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_manage_ols_dispatch(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_manage_ols_finance(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_manage_ols_gate(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ols_production(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ols_packing(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ols_dispatch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ols_finance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ols_gate(uuid) TO authenticated;

COMMENT ON FUNCTION public.can_manage_ols_production(uuid) IS 'Trace authority: manufacturing/production transitions.';
COMMENT ON FUNCTION public.can_manage_ols_packing(uuid) IS 'Trace authority: packed-ready carton transitions.';
COMMENT ON FUNCTION public.can_manage_ols_dispatch(uuid) IS 'Trace authority: dispatch clearance (DPL, shipping).';
COMMENT ON FUNCTION public.can_manage_ols_finance(uuid) IS 'Trace authority: financial/manufacturing-value transitions.';
COMMENT ON FUNCTION public.can_manage_ols_gate(uuid) IS 'Trace authority: physical gate release.';

-- =====================================================================
-- 2. Membership integrity: uniqueness the app never had, plus idempotency
--    keys for the governed RPCs below.
-- =====================================================================

ALTER TABLE public.ols_dpl_cartons
  ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now() NOT NULL;

ALTER TABLE public.ols_dpl_documents
  ADD COLUMN IF NOT EXISTS correlation_id text;

ALTER TABLE public.ols_finance_pi_cartons
  ADD COLUMN IF NOT EXISTS correlation_id text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ols_dpl_cartons_dpl_id_carton_id_key'
  ) THEN
    ALTER TABLE public.ols_dpl_cartons
      ADD CONSTRAINT ols_dpl_cartons_dpl_id_carton_id_key UNIQUE (dpl_id, carton_id);
  END IF;

  -- A carton may only ever belong to one DPL — the same integrity rule the
  -- Trace frontend now enforces client-side (dplMembership.ts), backed here
  -- so a direct table write cannot bypass it.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ols_dpl_cartons_carton_id_key'
  ) THEN
    ALTER TABLE public.ols_dpl_cartons
      ADD CONSTRAINT ols_dpl_cartons_carton_id_key UNIQUE (carton_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ols_finance_pi_cartons_pi_id_carton_id_key'
  ) THEN
    ALTER TABLE public.ols_finance_pi_cartons
      ADD CONSTRAINT ols_finance_pi_cartons_pi_id_carton_id_key UNIQUE (pi_id, carton_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ols_dpl_documents_correlation_id_key'
  ) THEN
    ALTER TABLE public.ols_dpl_documents
      ADD CONSTRAINT ols_dpl_documents_correlation_id_key UNIQUE (correlation_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ols_finance_pi_cartons_carton_correlation_key'
  ) THEN
    ALTER TABLE public.ols_finance_pi_cartons
      ADD CONSTRAINT ols_finance_pi_cartons_carton_correlation_key UNIQUE (carton_id, correlation_id);
  END IF;
END $$;

-- =====================================================================
-- 3. Audit-evidence immutability: ols_audit_logs and ols_print_logs are
--    insert-only. No application role (including the ones granted broader
--    write authority elsewhere in this migration) may UPDATE or DELETE a
--    row once written.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.ols_prevent_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'Audit evidence is append-only; % is not permitted on %', TG_OP, TG_TABLE_NAME
    USING ERRCODE = '0LSAU';
END;
$$;

REVOKE ALL ON FUNCTION public.ols_prevent_audit_mutation() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS ols_audit_logs_immutable ON public.ols_audit_logs;
CREATE TRIGGER ols_audit_logs_immutable
  BEFORE UPDATE OR DELETE ON public.ols_audit_logs
  FOR EACH ROW EXECUTE FUNCTION public.ols_prevent_audit_mutation();

DROP TRIGGER IF EXISTS ols_print_logs_immutable ON public.ols_print_logs;
CREATE TRIGGER ols_print_logs_immutable
  BEFORE UPDATE OR DELETE ON public.ols_print_logs
  FOR EACH ROW EXECUTE FUNCTION public.ols_prevent_audit_mutation();

-- Explicit deny-by-policy too (belt-and-suspenders with the trigger, and
-- exactly what oasis-trace/src/lib/audit.ts's own header comment already
-- specifies as the required backend closure).
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_audit_logs;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_print_logs;
CREATE POLICY "ols_audit_no_update" ON public.ols_audit_logs FOR UPDATE TO authenticated USING (false);
CREATE POLICY "ols_audit_no_delete" ON public.ols_audit_logs FOR DELETE TO authenticated USING (false);
CREATE POLICY "ols_print_logs_no_update" ON public.ols_print_logs FOR UPDATE TO authenticated USING (false);
CREATE POLICY "ols_print_logs_no_delete" ON public.ols_print_logs FOR DELETE TO authenticated USING (false);

-- =====================================================================
-- 4. Governed RPC: create a DPL with its full carton membership as one
--    atomic, idempotent, authority-checked operation. Supersedes Trace's
--    prior client-side sequence of one insert + N insert-loop calls.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.ols_create_dpl_with_cartons(
  p_dpl_no text,
  p_order_ref text,
  p_customer_name text,
  p_destination text,
  p_transport_mode text,
  p_carton_ids uuid[],
  p_correlation_id text
)
RETURNS public.ols_dpl_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_dpl public.ols_dpl_documents%ROWTYPE;
  v_existing public.ols_dpl_documents%ROWTYPE;
  v_totals record;
  v_carton_count integer;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_ols_dispatch(v_actor) THEN
    RAISE EXCEPTION 'Not authorised to create a DPL' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_carton_ids IS NULL OR array_length(p_carton_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one carton is required';
  END IF;

  -- Idempotent replay: a retry with the same correlation id returns the
  -- DPL already created by the first attempt instead of creating a second.
  SELECT * INTO v_existing FROM public.ols_dpl_documents WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  -- Lock every candidate carton so two concurrent DPL creations for the
  -- same order cannot both claim the same carton.
  PERFORM 1 FROM public.ols_cartons WHERE id = ANY (p_carton_ids) FOR UPDATE;

  SELECT count(*) INTO v_carton_count FROM public.ols_cartons WHERE id = ANY (p_carton_ids);
  IF v_carton_count <> array_length(p_carton_ids, 1) THEN
    RAISE EXCEPTION 'One or more cartons do not exist';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ols_cartons c
    WHERE c.id = ANY (p_carton_ids) AND c.status <> 'packed'
  ) THEN
    RAISE EXCEPTION 'Every carton must be packed before it can join a DPL' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ols_dpl_cartons dc WHERE dc.carton_id = ANY (p_carton_ids)
  ) THEN
    RAISE EXCEPTION 'One or more cartons already belong to a different DPL' USING ERRCODE = '23514';
  END IF;

  SELECT coalesce(sum(gross_weight), 0) AS gross, coalesce(sum(net_weight), 0) AS net
    INTO v_totals
    FROM public.ols_cartons WHERE id = ANY (p_carton_ids);

  INSERT INTO public.ols_dpl_documents (
    dpl_no, order_ref, customer_name, destination, transport_mode,
    prepared_by, total_cartons, total_gross, total_net, status, correlation_id
  ) VALUES (
    p_dpl_no, p_order_ref, p_customer_name, p_destination, p_transport_mode,
    v_actor, array_length(p_carton_ids, 1), v_totals.gross, v_totals.net, 'open', p_correlation_id
  )
  RETURNING * INTO v_dpl;

  INSERT INTO public.ols_dpl_cartons (dpl_id, carton_id, position)
  SELECT v_dpl.id, carton_id, row_number() OVER ()
  FROM unnest(p_carton_ids) AS carton_id;

  RETURN v_dpl;
END;
$$;

REVOKE ALL ON FUNCTION public.ols_create_dpl_with_cartons(text, text, text, text, text, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ols_create_dpl_with_cartons(text, text, text, text, text, uuid[], text) TO authenticated;
COMMENT ON FUNCTION public.ols_create_dpl_with_cartons(text, text, text, text, text, uuid[], text) IS
  'Atomic, idempotent, dispatch-authority-gated DPL creation with full carton membership. Superseded direct multi-write path removed from Trace (DPL.tsx generateDPL).';

-- =====================================================================
-- 5. Governed RPC: scan a carton onto a Finance PI. Fails closed when the
--    carton has no DPL membership (owner decision #3) and cannot mix
--    cartons from two DPLs on one PI (the DPL, not client UI state, is the
--    authoritative grouping key for "which PI is in progress").
-- =====================================================================

CREATE OR REPLACE FUNCTION public.ols_finance_pi_scan_carton(
  p_carton_id uuid,
  p_new_pi_no text,
  p_correlation_id text
)
RETURNS public.ols_finance_pi
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_carton public.ols_cartons%ROWTYPE;
  v_dpl_id uuid;
  v_pi public.ols_finance_pi%ROWTYPE;
  v_replay public.ols_finance_pi%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_ols_finance(v_actor) THEN
    RAISE EXCEPTION 'Not authorised to add cartons to a Finance PI' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_carton FROM public.ols_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton not found';
  END IF;

  -- Idempotent replay of the exact same scan: return the PI already
  -- produced by the first attempt rather than inserting a duplicate link.
  SELECT fp.* INTO v_replay
  FROM public.ols_finance_pi_cartons fpc
  JOIN public.ols_finance_pi fp ON fp.id = fpc.pi_id
  WHERE fpc.carton_id = p_carton_id AND fpc.correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_replay;
  END IF;

  IF EXISTS (SELECT 1 FROM public.ols_finance_pi_cartons WHERE carton_id = p_carton_id) THEN
    RAISE EXCEPTION 'Carton % is already on a Finance PI', v_carton.carton_no USING ERRCODE = '23514';
  END IF;

  SELECT dpl_id INTO v_dpl_id FROM public.ols_dpl_cartons WHERE carton_id = p_carton_id;
  IF v_dpl_id IS NULL THEN
    RAISE EXCEPTION 'Carton % is not linked to any DPL — add it to a DPL before Finance PI', v_carton.carton_no
      USING ERRCODE = '23514';
  END IF;

  -- Find-or-create the one open PI for this DPL. The DPL FK (not
  -- client-tracked "active PI" UI state) is the authoritative grouping
  -- key, so a PI can never end up mixing cartons from two different DPLs.
  SELECT * INTO v_pi FROM public.ols_finance_pi WHERE dpl_id = v_dpl_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    IF nullif(btrim(p_new_pi_no), '') IS NULL THEN
      RAISE EXCEPTION 'A new PI number is required to start a Finance PI for this DPL';
    END IF;
    INSERT INTO public.ols_finance_pi (pi_no, dpl_id, order_ref, customer_name, status, created_by)
    VALUES (p_new_pi_no, v_dpl_id, v_carton.order_ref, v_carton.customer_name, 'pending', v_actor)
    RETURNING * INTO v_pi;
  END IF;

  INSERT INTO public.ols_finance_pi_cartons (pi_id, carton_id, correlation_id)
  VALUES (v_pi.id, p_carton_id, p_correlation_id);

  UPDATE public.ols_cartons SET status = 'finance_received', updated_at = now() WHERE id = p_carton_id;

  RETURN v_pi;
END;
$$;

REVOKE ALL ON FUNCTION public.ols_finance_pi_scan_carton(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ols_finance_pi_scan_carton(uuid, text, text) TO authenticated;
COMMENT ON FUNCTION public.ols_finance_pi_scan_carton(uuid, text, text) IS
  'Atomic, idempotent, finance-authority-gated carton-to-PI scan. Fails closed on unlinked or cross-DPL cartons. Superseded direct multi-write path removed from Trace (FinancePI.tsx scanCarton).';

-- =====================================================================
-- 6. RLS: the two flows above become RPC-only (no direct INSERT policy —
--    SECURITY DEFINER RPCs bypass RLS as their owner). Every other ols_*
--    write path that is not yet RPC-governed gets a least-privilege
--    "internal staff" floor, replacing "any authenticated account".
-- =====================================================================

-- DPL documents / DPL carton membership: RPC-only writes.
DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_dpl_documents;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_dpl_documents;
DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_dpl_cartons;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_dpl_cartons;

-- Finance PI creation / carton linking: RPC-only writes. clearPI's status
-- transition (a different, not-yet-RPC'd flow) keeps direct UPDATE access,
-- now gated to finance authority instead of any authenticated account.
DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_finance_pi;
DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_finance_pi_cartons;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_finance_pi;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_finance_pi_cartons;
CREATE POLICY "ols_finance_pi_update_finance_authority" ON public.ols_finance_pi
  FOR UPDATE TO authenticated
  USING (public.can_manage_ols_finance(auth.uid()))
  WITH CHECK (public.can_manage_ols_finance(auth.uid()));

DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_finance_pi_lines;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_finance_pi_lines;
CREATE POLICY "ols_finance_pi_lines_write_finance_authority" ON public.ols_finance_pi_lines
  FOR INSERT TO authenticated
  WITH CHECK (public.can_manage_ols_finance(auth.uid()));
CREATE POLICY "ols_finance_pi_lines_update_finance_authority" ON public.ols_finance_pi_lines
  FOR UPDATE TO authenticated
  USING (public.can_manage_ols_finance(auth.uid()))
  WITH CHECK (public.can_manage_ols_finance(auth.uid()));

-- ols_cartons: written by multiple not-yet-RPC'd flows (Cartonization,
-- ShippingLabel, FinancePI.clearPI) with different authorities each. Apply
-- the internal-staff floor rather than guess a single narrow authority and
-- break a legitimate flow; finer per-transition RPCs are tracked follow-up.
DROP POLICY IF EXISTS "ols_auth_write" ON public.ols_cartons;
DROP POLICY IF EXISTS "ols_auth_update" ON public.ols_cartons;
CREATE POLICY "ols_cartons_write_internal_staff" ON public.ols_cartons
  FOR INSERT TO authenticated
  WITH CHECK (public.is_internal_staff(auth.uid()));
CREATE POLICY "ols_cartons_update_internal_staff" ON public.ols_cartons
  FOR UPDATE TO authenticated
  USING (public.is_internal_staff(auth.uid()))
  WITH CHECK (public.is_internal_staff(auth.uid()));

-- Every remaining ols_* table with a blanket "to authenticated using(true)"
-- write/update policy: same internal-staff floor, mechanically applied.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ols_audit_logs', 'ols_carton_contents', 'ols_departments',
    'ols_dispatch_document_bundles', 'ols_gate_scans',
    'ols_inventory_movements', 'ols_label_templates',
    'ols_manual_override_logs', 'ols_orders_cache', 'ols_permissions',
    'ols_print_jobs', 'ols_print_logs', 'ols_printer_settings',
    'ols_printers', 'ols_production_batches', 'ols_production_labels',
    'ols_products_cache', 'ols_profiles_light', 'ols_reprint_requests',
    'ols_scan_history', 'ols_settings', 'ols_shipping_labels',
    'ols_stock_units'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'ols_auth_write', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'ols_auth_update', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.is_internal_staff(auth.uid()))',
      t || '_write_internal_staff', t
    );
    -- ols_audit_logs/ols_print_logs already have explicit UPDATE-deny
    -- policies from section 3 above — do not also grant one here.
    IF t NOT IN ('ols_audit_logs', 'ols_print_logs') THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.is_internal_staff(auth.uid())) WITH CHECK (public.is_internal_staff(auth.uid()))',
        t || '_update_internal_staff', t
      );
    END IF;
  END LOOP;
END $$;
