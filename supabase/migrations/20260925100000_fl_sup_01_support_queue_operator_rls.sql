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
