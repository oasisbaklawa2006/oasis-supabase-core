-- Validate the expanded source-provenance domain outside the DDL transaction
-- that replaced the constraint, reducing the lock held by the PF-4 migration.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.orders
  VALIDATE CONSTRAINT orders_order_origin_check;
