-- Only when Buyer Genie CAS callers are disabled and all requests drained.
drop function if exists public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric);
