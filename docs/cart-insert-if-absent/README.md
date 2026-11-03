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

## Lock order versus remove/update (repaired in `20261102091000_customer_cart_mutation_lock_order_v1`)
Reproduced deterministically on the Supabase Postgres 17 image: the cart RPCs took locks in two orders.
`add_*`, `add_*_if_absent`, `clear_*`, `get_*`, `submit_*`: company advisory lock -> draft row (FOR UPDATE) -> line rows.
`remove_*` and `update_*`: line row (FOR UPDATE) -> draft row (audit FK key-share, then readiness recompute FOR UPDATE), with no advisory lock.
Two calls of the two families on one company wait on each other's tuple locks and PostgreSQL aborts one with `40P01`. This is NOT introduced by
`add_customer_order_draft_line_if_absent_v1`: it already exists between the released upsert/clear and remove/update.
Even a different product in the same draft can trigger it (the draft row is shared), so a fix confined to the new function is insufficient.

Repair (smallest): `remove_` and `update_customer_order_draft_line_v1` take the same per-company advisory lock, same key, before any line or draft lock.
All five cart mutations then serialise per company on one lock first. Bodies are otherwise byte-identical to the released definitions (production hashes
`f15eba03...` and `4ddf97c7...` verified 2026-11-02); the rollback restores them verbatim. Other companies are not affected.

Evidence (24-client pgbench mixed workload on ONE company: if_absent / upsert / remove / update; real Supabase image):
| Variant | Deadlock failures |
|---|---|
| released functions only (no #477 at all) | 7.4% |
| #477 if_absent as originally reviewed | 9.9% |
| if_absent pre-locks its line only (rejected: smaller, still deadlocks) | 6.7% |
| company lock first in remove/update (this repair) | **0 of 8,093 (24 clients) and 0 of 8,523 (48 clients)**; released-ops-only mix 0 of 5,301 |
Accepted scenario (queued if_absent + remove of the same product), before: `40P01` 2/2; after: no abort 3/3. Differential run of a 14-step scenario on the old and new functions:
identical results, quantities, price snapshots, readiness and audit sequence. Parallel/idempotency/stale-read/tenant/rollback checks: 9/9 (24-way if_absent -> 1 insert, 0 errors;
40 concurrent remove+if_absent rounds -> 0 deadlocks; company B not delayed by company A's lock; rejected update releases the lock).
Not proven: PostgREST/GoTrue behaviour, production volumes. Callers should still treat `40P01` as retryable; Buyer #69 retries the bulk add at most 3 times.
