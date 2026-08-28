-- R4 3PGS launch-readiness: validate the relaxed supplier-receipt provenance
-- constraint in its own migration transaction so the short ACCESS EXCLUSIVE
-- lock from the preceding ADD CONSTRAINT ... NOT VALID has already committed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.b2b_inventory_receipts
  VALIDATE CONSTRAINT b2b_inventory_receipts_source_reference_check;
