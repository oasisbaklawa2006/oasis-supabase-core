-- Preserve Finance/Exit read authority established by the prior hardening pass.
-- The invoice-date correction must not re-open service-role execution on the
-- internal Finance/Exit projection RPC.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

REVOKE EXECUTE ON FUNCTION public.get_finance_exit_facts_v1(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_finance_exit_facts_v1(uuid) TO authenticated;
