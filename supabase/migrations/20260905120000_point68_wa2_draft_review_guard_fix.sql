-- POINT68: repair WA-2 draft write guard so review/correction RPCs can execute.
-- The WA-3 hardening reused tg_table_name (always NULL) and PL/pgSQL evaluates both
-- sides of AND, so sales_order_drafts writes hit new.action and fail closed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.wa2_guard_sales_order_draft_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL OR NOT public.has_whatsapp_permission('wa.draft.manage') THEN
    RAISE EXCEPTION 'WA2_DRAFT_MANAGE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF TG_TABLE_NAME = 'sales_order_drafts' THEN
    IF (NEW.status = 'APPROVED_FOR_SO' OR NEW.promoted_order_id IS NOT NULL)
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status OR OLD.promoted_order_id IS DISTINCT FROM NEW.promoted_order_id)
       AND NOT public.has_whatsapp_permission('wa.draft.promote') THEN
      RAISE EXCEPTION 'WA2_DRAFT_PROMOTE_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
  ELSIF TG_TABLE_NAME = 'sales_order_draft_audit_log' THEN
    IF NEW.action = 'APPROVE'
       AND NOT public.has_whatsapp_permission('wa.draft.promote') THEN
      RAISE EXCEPTION 'WA2_DRAFT_PROMOTE_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.wa2_guard_sales_order_draft_write() IS
  'WA-2/WA-3 draft write guard. Uses TG_TABLE_NAME so audit-log-only fields are never read from draft rows.';
