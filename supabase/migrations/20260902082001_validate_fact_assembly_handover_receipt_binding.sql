-- FACT-E2E / Core #176: validate the Assembly handover lineage constraint
-- in its own migration transaction so the short ACCESS EXCLUSIVE lock from
-- ADD CONSTRAINT ... NOT VALID has already committed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.b2b_inventory_receipts
  VALIDATE CONSTRAINT b2b_inventory_receipts_assembly_handover_reference_check;
