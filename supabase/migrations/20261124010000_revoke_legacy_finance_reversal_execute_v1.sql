-- Retire the single-actor Finance reversal bypass.
--
-- public.reverse_finance_control_v1 (immediate reversal) checks only that the caller is a Finance clearance actor.
-- It has no maker-checker and no AAL2 requirement, so one Finance user could reverse a hold alone, bypassing the
-- two-step flow added in 20261109102000 (request_finance_reversal_v1 -> decide_finance_reversal_v1 by a DIFFERENT
-- actor -> complete_finance_reversal_v1, all Finance + AAL2).
--
-- Owner decision (Master Appverse Wave 1 closeout, Run 2): no single-actor break-glass path. The two-step flow is
-- the only supported reversal route. This migration only removes EXECUTE; it does not drop or alter the function,
-- change any other grant, or touch any data. The function body, signature and the append-only finance_control_events
-- history are unchanged, and the two-step functions keep their existing grants.
--
-- Rollback (explicit owner approval only): GRANT EXECUTE ON FUNCTION
--   public.reverse_finance_control_v1(uuid,text,text,text,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.reverse_finance_control_v1(uuid, text, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
