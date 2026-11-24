-- Retire the single-actor Finance reversal bypass.
--
-- public.reverse_finance_control_v1 (immediate reversal) checks only that the caller is a Finance clearance actor.
-- It has no maker-checker and no AAL2 requirement, so one Finance user could reverse a hold alone, bypassing the
-- two-step flow added in 20261109102000 (request_finance_reversal_v1 -> decide_finance_reversal_v1 by a DIFFERENT
-- actor -> complete_finance_reversal_v1, all Finance + AAL2).
--
-- Owner decision (Master Appverse Wave 1 closeout, Run 2): no single-actor break-glass path. For ORDER and DISPATCH
-- events the two-step flow is the only supported reversal route. This migration only removes EXECUTE; it does not
-- drop or alter the function, change any other grant, or touch any data. The function body, signature and the
-- append-only finance_control_events history are unchanged, and the two-step functions keep their existing grants.
--
-- COMPANY and INVOICE events (and any event without an order) are NOT covered by the two-step flow:
-- request_finance_reversal_v1 and complete_finance_reversal_v1 fail closed on them with
-- FINANCE_REVERSAL_SCOPE_SNAPSHOT_UNAVAILABLE, and 20261109102000 preserved this legacy function for them "until a
-- separately approved cutover". That cutover is approved here (Option 1, owner approval recorded at Gate 2B):
--   * Single-actor COMPANY/INVOICE reversal is retired for the November 30 release. There is deliberately no
--     reversal route for those scopes after this migration, and existing COMPANY/INVOICE events cannot be reversed
--     through the API until the follow-up below exists.
--   * A two-step (maker-checker, AAL2) COMPANY/INVOICE reversal is scoped post-launch for December, only if needed.
--     It is not part of this migration and not a prerequisite for it.
--   * Do not restore EXECUTE on this function to cover those scopes; a governed route is the only acceptable path.
--
-- Rollback (explicit owner approval only): GRANT EXECUTE ON FUNCTION
--   public.reverse_finance_control_v1(uuid,text,text,text,text,uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.reverse_finance_control_v1(uuid, text, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
