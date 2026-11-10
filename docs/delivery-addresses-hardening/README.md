# delivery_addresses direct-write hardening (Core, draft)

Combined draft PR #519 includes the governed Buyer address/transporter RPC migration `20261109104000_buyer_delivery_address_and_saved_transporter_authority_v1.sql` (original PR #510) followed by `20261109104100_delivery_addresses_direct_write_hardening_v1.sql` (original stacked PR #513). Their rollback and pgTAP files remain separate and in chronological order. The hardening migration fails closed unless the prior six governed RPCs exist and satisfy the recorded ownership/security requirements. No production deployment or direct-write cutover is authorized by this draft.

## Finding (reproduced, not assumed)
Production `public.delivery_addresses` (read-only, 2026-11-02): RLS enabled, not forced, 11 rows; `anon` and `authenticated` hold SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN; six policies, all `TO public`: two SELECT, two INSERT (via `profiles` and via legacy `users`), one UPDATE (USING only, so the new row is checked by the same expression), one DELETE; no triggers; no check constraints; no FK dependents. The same table, policies and ACL were recreated on the Supabase Postgres 17.6 image and probed as eight realistic actors (anon, approved buyer, pending, rejected, frozen-company buyer, buyer of another tenant, internal admin, signed-in user without a profile) with JWT claims set as PostgREST sets them. Full matrices: `evidence/probe_before.md` and `evidence/probe_after.md` in the Run 10 package.

| Question | Result before this migration |
|---|---|
| Cross-tenant read | **Prevented by RLS** (0 rows of another tenant for every actor) |
| Cross-tenant insert / update / delete / move row into another tenant / pull a foreign row / upsert onto a foreign row | **Prevented by RLS** (denied or 0 rows) for every actor |
| Forged `company_id` | Prevented (policy check) |
| Forged `user_id` (attribute a row to another tenant's buyer) | **Allowed** within the actor's own company |
| Writes by users who are NOT eligible Buyers (pending, rejected, frozen-company) | **Allowed**: insert, update, delete (RPC would answer BUYER_ADDRESS_ELIGIBILITY_REQUIRED) |
| RPC validation bypass: 10,000-character label with a control character, second default address | **Allowed** |
| Unfiltered `DELETE` | Deletes every row of the actor's own company only |
| `TRUNCATE` | **Allowed for anon and authenticated, ignores RLS, empties every tenant.** Reachable only with a SQL-level role connection (PostgREST does not expose TRUNCATE), so not exploitable with an anon/user key alone. |

Conclusion: an exploitable authorisation gap exists inside a tenant (ineligible users modify the address book and skip the governed validation), plus a TRUNCATE/TRIGGER/REFERENCES privilege that should not exist. Cross-tenant isolation holds. Because it is demonstrated, no 14-day observation period is required; the gate is functional (the Buyer build in production must write addresses only through the RPCs, which Buyer main and PR #69 already do).

## Change
Drop the four write policies; `revoke all` from `anon`; `revoke all` from `authenticated` and re-grant `SELECT`. `service_role` and the SECURITY DEFINER RPCs (owned by the table owner, RLS not forced) are unaffected. Guards refuse to run unless the six governed RPCs exist, are SECURITY DEFINER and are owned by the table owner, and RLS is not forced.

## After
All eight actors are denied for every write and TRUNCATE (42501); `anon` cannot read; reads of own-company rows are unchanged; service_role still writes; RPC create/list/delete and transporter RPC work; ineligible users are refused by the RPC. pgTAP 24/24 (fails 11 assertions on the unhardened table). Rollback restores the exact policies and `arwdDxtm` grants.

## Known callers (checked)
Buyer main / PR #69: RPCs only. Central: reads only. Core scripts and edge cert harnesses: service_role. No Core SQL function writes the table outside the #478 definer RPCs.

## Not covered
Pending/rejected users can still READ their own company's addresses through the unchanged SELECT policies (separate decision). PostgREST/GoTrue were not run; JWT claims were simulated. Platform-wide TRUNCATE hygiene on other tables is a separate migration.
