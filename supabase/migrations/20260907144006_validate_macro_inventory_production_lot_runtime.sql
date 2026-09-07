-- MACRO INVENTORY: validate production-lot runtime constraints from 44005 in a
-- separate transaction so live-ledger scans do not extend prior lock windows.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

ALTER TABLE public.inventory_lot_positions
  VALIDATE CONSTRAINT inventory_lot_positions_origin_check;

ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;
