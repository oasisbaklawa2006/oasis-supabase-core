-- P0 follow-up for CodeRabbit exact-head review on Core #183.
--
-- The preceding RLS hardening migration narrowed INSERT/UPDATE/DELETE policy
-- authority, but historical baseline GRANT ALL may leave non-DML table
-- privileges such as TRUNCATE, REFERENCES and TRIGGER on `authenticated`.
-- RLS does not protect TRUNCATE, so close the table privilege surface to the
-- exact client contract while preserving governed SECURITY DEFINER RPCs.
--
-- Forward-only privilege correction. No governed business rows are changed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Finance evidence is append-only through the finance-only INSERT RLS policy.
-- Authenticated clients require only SELECT + INSERT; all other table
-- privileges are removed explicitly by rebuilding the grant set.
REVOKE ALL ON TABLE public.finance_review_evidence FROM anon;
REVOKE ALL ON TABLE public.finance_review_evidence FROM authenticated;
GRANT SELECT, INSERT ON TABLE public.finance_review_evidence TO authenticated;

-- Inventory reservations remain staff-readable but RPC-only for mutation.
-- Authenticated clients require SELECT only; governed SECURITY DEFINER RPCs
-- execute under their owner authority and are not weakened by this revocation.
REVOKE ALL ON TABLE public.inventory_reservations FROM anon;
REVOKE ALL ON TABLE public.inventory_reservations FROM authenticated;
GRANT SELECT ON TABLE public.inventory_reservations TO authenticated;
