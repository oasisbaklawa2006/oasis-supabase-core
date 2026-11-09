-- Rollback for 20261109105000_customer_order_draft_add_if_absent_v1.sql.
-- Safe for data: the function is additive and holds no data.
-- Buyer impact: Buyer builds that call it (bulk add from Reorder / QuickOrder / Catalogue / AI order) FAIL CLOSED when the function is
-- absent (no read-then-upsert fallback; partial results are reported to the buyer). Roll those Buyer builds back first, or accept that bulk add
-- is unavailable until the function is restored. Single-line add (add_customer_order_draft_line_v1) is unaffected.
drop function if exists public.add_customer_order_draft_line_if_absent_v1(uuid, numeric);
