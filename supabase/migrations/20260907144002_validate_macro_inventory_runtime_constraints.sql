-- MACRO INVENTORY: validate NOT VALID constraints in a separate transaction
-- so the live inventory_movements ledger scan does not extend the prior
-- migration's ACCESS EXCLUSIVE lock window.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

ALTER TABLE public.inventory_reservation_allocations
  VALIDATE CONSTRAINT inventory_reservation_allocations_entity_type_check;

ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;
