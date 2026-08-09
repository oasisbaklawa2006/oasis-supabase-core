-- Point 27 (oasis-ai-studio), Finding 2: pricing/MOQ commercial rule authority
-- belongs to Central + Core, not AI Studio. The client-side fix (AI Studio no
-- longer self-approves and only ever proposes catalogue drafts) is already
-- deployed. This migration closes the matching server-side gap: product_pricing_rules
-- and product_moq_rules currently grant INSERT/UPDATE/DELETE to anon and
-- authenticated directly (leftover from before the catalogue-draft governance
-- layer existed), even though every legitimate write path already goes
-- through approve_catalogue_pricing_draft / approve_catalogue_moq_draft, both
-- already gated by is_catalogue_reviewer() via approve_catalogue_draft_internal
-- and defined to run with elevated definer privileges. Those RPCs do not
-- depend on the caller holding table-level write grants, so revoking the
-- grants below does not affect the governed approval path.
--
-- product_pricing_rules is read (SELECT only) by the live customer-checkout
-- RPC in 20260807171000_customer_order_draft_v1.sql; SELECT grants for
-- authenticated are intentionally left untouched here.

revoke insert, update, delete on table "public"."product_pricing_rules" from "anon";
revoke insert, update, delete on table "public"."product_pricing_rules" from "authenticated";

revoke insert, update, delete on table "public"."product_moq_rules" from "anon";
revoke insert, update, delete on table "public"."product_moq_rules" from "authenticated";
