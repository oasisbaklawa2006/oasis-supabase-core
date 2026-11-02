-- Rollback for 20261102090000_customer_order_draft_add_if_absent_v1.sql.
-- Safe: the function is additive and holds no data. Buyer builds that call it must be rolled back first
-- (the Buyer falls back to its guarded read-then-write path when the function is absent).
drop function if exists public.add_customer_order_draft_line_if_absent_v1(uuid, numeric);
