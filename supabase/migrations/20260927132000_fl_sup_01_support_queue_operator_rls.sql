-- FL-SUP-01: align support_tickets staff queue RLS with the canonical Support operator.
--
-- The legacy support_tickets_admin_all policy only recognised lowercase
-- users.role values admin/super_admin. Canonical staff identities resolved via
-- get_user_role() — including SUPPORT_EXECUTIVE — could reach Central's support
-- UI yet receive zero queue rows. This migration narrows staff queue authority
-- to ADMIN, SUPER_ADMIN and SUPPORT_EXECUTIVE without opening the queue to all
-- internal staff and without weakening customer isolation policies.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.is_support_ticket_queue_operator(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
  SELECT public.is_internal_staff(_user_id)
    AND upper(coalesce(public.get_user_role(_user_id), '')) = ANY (
      ARRAY['ADMIN', 'SUPER_ADMIN', 'SUPPORT_EXECUTIVE']::text[]
    );
$$;

COMMENT ON FUNCTION public.is_support_ticket_queue_operator(uuid) IS
  'True for active internal staff authorised to operate the customer support ticket queue (ADMIN, SUPER_ADMIN, SUPPORT_EXECUTIVE).';

REVOKE ALL ON FUNCTION public.is_support_ticket_queue_operator(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_support_ticket_queue_operator(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS support_tickets_admin_all ON public.support_tickets;

CREATE POLICY support_tickets_queue_operator_select
  ON public.support_tickets
  FOR SELECT
  TO authenticated
  USING (public.is_support_ticket_queue_operator(auth.uid()));

CREATE POLICY support_tickets_queue_operator_update
  ON public.support_tickets
  FOR UPDATE
  TO authenticated
  USING (public.is_support_ticket_queue_operator(auth.uid()))
  WITH CHECK (public.is_support_ticket_queue_operator(auth.uid()));

CREATE POLICY support_tickets_admin_insert
  ON public.support_tickets
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_internal_staff(auth.uid())
    AND upper(coalesce(public.get_user_role(auth.uid()), '')) = ANY (
      ARRAY['ADMIN', 'SUPER_ADMIN']::text[]
    )
  );

CREATE POLICY support_tickets_admin_delete
  ON public.support_tickets
  FOR DELETE
  TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    AND upper(coalesce(public.get_user_role(auth.uid()), '')) = ANY (
      ARRAY['ADMIN', 'SUPER_ADMIN']::text[]
    )
  );


-- Least-privilege write surface: queue operators/admins can mutate workflow
-- state only. Original customer/tenant/source fields are not client-updatable.
REVOKE UPDATE ON TABLE public.support_tickets FROM authenticated;
GRANT UPDATE (
  status,
  resolution_notes,
  routed_to_department,
  assigned_employee_id,
  sla_first_response_at,
  sla_action_at,
  sla_resolved_at,
  sla_first_response_due,
  sla_action_due,
  sla_resolution_due,
  sla_state,
  severity,
  estimated_financial_loss,
  customer_rating,
  admin_rating_speed,
  admin_rating_quality,
  admin_rating_communication,
  rejection_reason_template,
  resolution_template_used,
  ai_rewritten_reply,
  escalated_to_hod,
  commission_blocked
) ON public.support_tickets TO authenticated;


-- Release-wave WhatsApp callback persistence: status transition and immutable
-- callback evidence must commit atomically. Row locking makes duplicate or
-- out-of-order provider retries no-ops and prevents duplicate audit evidence.
CREATE OR REPLACE FUNCTION public.persist_whatsapp_operator_reply_provider_status(
  p_provider_message_id text,
  p_status text,
  p_evidence jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_temp
AS $$
DECLARE
  v_reply public.whatsapp_operator_reply_outbox%ROWTYPE;
  v_target text := upper(btrim(coalesce(p_status, '')));
  v_current_rank integer;
  v_target_rank integer;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'WA5_SERVICE_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF nullif(btrim(coalesce(p_provider_message_id, '')), '') IS NULL THEN
    RETURN jsonb_build_object('matched', false, 'updated', false, 'status', null);
  END IF;

  IF v_target NOT IN ('ACCEPTED', 'DELIVERED', 'READ') THEN
    RAISE EXCEPTION 'WA5_INVALID_PROVIDER_STATUS' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_reply
  FROM public.whatsapp_operator_reply_outbox
  WHERE provider_message_id = btrim(p_provider_message_id)
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('matched', false, 'updated', false, 'status', null);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.whatsapp_operator_reply_outbox
    WHERE provider_message_id = btrim(p_provider_message_id)
      AND id <> v_reply.id
  ) THEN
    RAISE EXCEPTION 'WA_STATUS_PROVIDER_MESSAGE_AMBIGUOUS' USING ERRCODE = 'P0001';
  END IF;

  v_current_rank := CASE upper(v_reply.status)
    WHEN 'QUEUED' THEN 0
    WHEN 'SENDING' THEN 1
    WHEN 'ACCEPTANCE_UNKNOWN' THEN 1
    WHEN 'ACCEPTED' THEN 2
    WHEN 'DELIVERED' THEN 3
    WHEN 'READ' THEN 4
    ELSE -1
  END;

  v_target_rank := CASE v_target
    WHEN 'ACCEPTED' THEN 2
    WHEN 'DELIVERED' THEN 3
    WHEN 'READ' THEN 4
    ELSE -1
  END;

  IF v_current_rank < 0 THEN
    RAISE EXCEPTION 'WA_STATUS_BOUNDARY_OR_REGRESSION' USING ERRCODE = 'P0001';
  END IF;

  IF v_target_rank <= v_current_rank THEN
    RETURN jsonb_build_object(
      'matched', true,
      'updated', false,
      'status', upper(v_reply.status)
    );
  END IF;

  UPDATE public.whatsapp_operator_reply_outbox
  SET status = v_target,
      accepted_at = coalesce(accepted_at, v_now),
      delivered_at = CASE
        WHEN v_target IN ('DELIVERED', 'READ') THEN coalesce(delivered_at, v_now)
        ELSE delivered_at
      END,
      read_at = CASE
        WHEN v_target = 'READ' THEN coalesce(read_at, v_now)
        ELSE read_at
      END,
      lease_token = null,
      lease_expires_at = null,
      last_error_code = null,
      last_error_detail = null,
      updated_at = v_now
  WHERE id = v_reply.id;

  INSERT INTO public.whatsapp_operator_reply_events(
    reply_id,
    event_type,
    actor_id,
    evidence
  )
  VALUES (
    v_reply.id,
    'PROVIDER_STATUS_CALLBACK',
    null,
    coalesce(p_evidence, '{}'::jsonb) || jsonb_build_object(
      'provider_status', lower(btrim(p_status)),
      'target_status', v_target,
      'provider_message_id_present', true
    )
  );

  RETURN jsonb_build_object(
    'matched', true,
    'updated', true,
    'status', v_target
  );
END;
$$;

COMMENT ON FUNCTION public.persist_whatsapp_operator_reply_provider_status(text, text, jsonb) IS
  'Service-role-only atomic provider callback persistence. Locks the reply row, advances status monotonically, and writes immutable audit evidence in the same transaction.';

REVOKE ALL ON FUNCTION public.persist_whatsapp_operator_reply_provider_status(text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.persist_whatsapp_operator_reply_provider_status(text, text, jsonb)
  TO service_role;


-- Support operators may manage queue state, but ticket/customer identity is immutable.
-- Without this guard, a broad queue UPDATE could move a ticket to another company
-- or point it at another company's order, leaking customer-safe projection data.
CREATE OR REPLACE FUNCTION public.guard_support_ticket_identity_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, public
AS $$
BEGIN
  IF new.id IS DISTINCT FROM old.id
     OR new.company_id IS DISTINCT FROM old.company_id
     OR new.order_id IS DISTINCT FROM old.order_id
     OR new.created_by IS DISTINCT FROM old.created_by
     OR new.user_id IS DISTINCT FROM old.user_id
     OR new.idempotency_key IS DISTINCT FROM old.idempotency_key
     OR new.created_at IS DISTINCT FROM old.created_at THEN
    RAISE EXCEPTION 'SUPPORT_TICKET_IDENTITY_IMMUTABLE' USING ERRCODE = '42501';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.guard_support_ticket_identity_immutable() IS
  'Fail-closed UPDATE guard for support_tickets identity/tenant lineage. Queue operators may change operational workflow fields but cannot rebind a ticket to another company, order, creator, user, idempotency key, creation timestamp, or ticket id.';

REVOKE ALL ON FUNCTION public.guard_support_ticket_identity_immutable() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS support_ticket_identity_immutable_trg ON public.support_tickets;
CREATE TRIGGER support_ticket_identity_immutable_trg
BEFORE UPDATE OF id, company_id, order_id, created_by, user_id, idempotency_key, created_at
ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.guard_support_ticket_identity_immutable();
