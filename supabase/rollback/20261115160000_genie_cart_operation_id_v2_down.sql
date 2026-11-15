-- Core #535: run ONLY after Buyer G3 v2 callers are disabled and all
-- in-flight Genie operations are drained. This drops durable retry receipts;
-- removing receipts while clients may replay risks duplicate/unknown results.
drop function if exists public.add_customer_order_draft_line_genie_v2(uuid,numeric,uuid);
drop table if exists public.customer_genie_cart_operations;
