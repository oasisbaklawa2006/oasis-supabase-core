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
- 24-way concurrency run (24 parallel callers, two users of one company, one product): exactly 1 insert, 23 report the winner's quantity, 0 errors, 1 line row, 1 active draft. Results: `concurrency_results_local_replay.json` (23/23). The driver script is local tooling (shell-out to psql) and is intentionally not committed; it is kept with the Run 6/7 evidence package.
- Tenant isolation, unauthenticated, non-buyer, MOQ violation, unknown product, zero quantity, grants: covered.
Not proven here: behaviour on the Supabase image / PostgREST, RLS-forced role switching, production data volumes.

## Known limitation: lock order versus `remove_customer_order_draft_line_v1` (open review thread)
Reproduced deterministically on the real Supabase Postgres image (2 of 2 runs): a session holding the draft row lock, `add_customer_order_draft_line_if_absent_v1`
queued behind it for the same product, and `remove_customer_order_draft_line_v1` for that product's existing line started second. The remove deletes the
line and then waits for the draft row; the add takes the draft row and then waits on the uncommitted delete. PostgreSQL aborts one request with `40P01
deadlock detected` (in both runs the remove was the victim). The aborted transaction rolls back completely; the line and its quantity stay intact; a retry
of the whole request succeeds. The same ordering already exists between the released upsert/update RPCs and remove; this PR does not introduce it.
Requires one company adding and removing the same product at the same instant. Not fixed here (a fix changes released RPCs); it needs an owner decision:
accept with caller retry on `40P01`, or a separate hardening migration making every cart mutation take the company lock first.
