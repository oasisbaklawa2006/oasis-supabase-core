-- Contract test for migration:
-- 20260918010000_auth01_buyer_rpc_identity_gate_hardening.sql
begin;
select plan(1);
select ok(
  pg_get_functiondef('public.auth_buyer_company_id()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  '20260918010000_auth01_buyer_rpc_identity_gate_hardening.sql binds legacy Buyer company resolution to the canonical Buyer eligibility authority'
);
select * from finish();
rollback;
