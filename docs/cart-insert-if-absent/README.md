# Buyer cart: atomic insert-if-absent

Migration: `supabase/migrations/20261102090000_customer_order_draft_add_if_absent_v1.sql` (additive, one new function).
Rollback: `supabase/rollback/20261102090000_customer_order_draft_add_if_absent_v1_down.sql` (drops the function; verified).

## Defect closed
`add_customer_order_draft_line_v1` is an upsert (`ON CONFLICT ... DO UPDATE SET quantity = excluded.quantity`).
Buyer Quick order / Reorder read the cart, decide a product is absent, then upsert: if another session of the same
company adds the product in between, the newer quantity is silently replaced (reproduced: 27 -> 9, test 3c).

## Behaviour
Same authority as the upsert (auth, approved-buyer company, server-resolved price/MOQ/increment/carton rules,
per-company advisory lock `customer_draft:<company>`), but `ON CONFLICT DO NOTHING`. Returns
`(draft_id, line_id, inserted, existing_quantity, readiness_status, readiness_issues)`. `inserted=false` leaves the line untouched.
Audit: reuses action `ADD_LINE` with `detail.mode='if_absent'` (no audit-constraint change).

## Evidence (local PostgreSQL replay with the Supabase shim; NOT the Supabase image, JWTs are simulated)
- `supabase/tests/20261102090000_customer_order_draft_add_if_absent_v1.sql`: 13 pgTAP assertions, all ok.
- `concurrency_test.py` (24 parallel callers, two users of one company, one product): exactly 1 insert, 23 report the winner's quantity, 0 errors, 1 line row, 1 active draft. Results: `concurrency_results_local_replay.json` (23/23).
- Tenant isolation, unauthenticated, non-buyer, MOQ violation, unknown product, zero quantity, grants: covered.
Not proven here: behaviour on the Supabase image / PostgREST, RLS-forced role switching, production data volumes.
