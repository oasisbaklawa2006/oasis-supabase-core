# Core #488 — Buyer checkout quote-consent boundary (caller / ACL census)

**Provenance:** `oasis-supabase-core` @ `645899439fe0a84806238b9114649eb2c3785a75` (pre-fix main) with draft enforcement in migration `20261101040000_customer_checkout_legacy_submit_quote_consent_barrier_v1.sql`.

**Production project (read-only facts from issue context):** `tcxvcatsqqertcnycuop`.

## RPC inventory (public schema, Data API exposed)

| Function | Signature | SECURITY DEFINER | Pre-fix `authenticated` EXECUTE | Intended buyer entrypoint |
|----------|-----------|------------------|-----------------------------------|---------------------------|
| `customer_checkout_quote_v1` | `()` → `jsonb` | yes | yes | Quote + MD5 fingerprint |
| `submit_customer_order_quoted_v1` | `(text,text,date)` → checkout rowset | yes | yes | **Binding submit with consent** |
| `submit_customer_order_v1` | `(text,date)` → checkout rowset | yes | **yes (bypass risk)** | Internal canonical writer only |

`anon` / `PUBLIC`: no EXECUTE on any of the above (explicit REVOKE in migrations `20260807172000`, `20261002181220`, `20261022150000`).

## Caller census (repository + effective paths)

| Caller class | `submit_customer_order_v1` | `submit_customer_order_quoted_v1` | Notes |
|--------------|----------------------------|-----------------------------------|-------|
| Buyer mobile / PostgREST (`authenticated` JWT) | **Direct RPC (pre-fix)** | Intended path post Buyer #65 | UI can gate; server ACL was the gap |
| `submit_customer_order_quoted_v1` (internal) | Delegates in-transaction | — | Owner-privileged; unchanged by ACL migration |
| `service_role` PostgREST / edge | Granted EXECUTE | Granted EXECUTE | No in-repo edge function references located |
| pgTAP / CI fixtures | Was direct; tests updated to quoted path | Exercised | Non-production only |
| WhatsApp / staff promotion RPCs | No reference | No reference | Separate order-creation writers |

**Edge / functions search:** no `submit_customer_order_v1` string matches outside Core SQL/tests (Buyer app is out of repo boundary).

## Least-privilege design (draft)

1. **Keep** single canonical writer (`submit_customer_order_v1`) — no duplicate INSERT authority.
2. **Revoke** `EXECUTE` on `submit_customer_order_v1(text,date)` from `authenticated` (and re-close `PUBLIC`/`anon`).
3. **Retain** `EXECUTE` for `service_role` and SECURITY DEFINER owner-mediated calls from `submit_customer_order_quoted_v1`.
4. **Rollback:** `GRANT EXECUTE ... TO authenticated` (Buyer must ship quoted-only client first in production).

## Impact matrix

| Surface | Pre-fix | Post-fix | Regression risk |
|---------|---------|----------|-----------------|
| Buyer checkout SO create | Legacy or quoted RPC | Quoted only | Old Buyer builds calling legacy RPC fail until updated (Buyer #65 aligns) |
| Quote refresh | `customer_checkout_quote_v1` | unchanged | Low |
| Idempotent replay | Both paths (legacy unguarded) | Quoted with immutable snapshot fingerprint | Low — strengthened |
| WhatsApp / service_role checkout | service_role legacy EXECUTE | unchanged | Low — verified privilege retained |
| Internal quoted → legacy delegation | SECURITY DEFINER | unchanged | Low |

## Cross-app live caller and safe deployment sequencing (audited 7 Nov 2026)

The original Core-only caller scan does **not** establish that external clients have
stopped calling the legacy RPC. A separate Central default-branch source audit
found an **active web Buyer checkout** at
`src/pages/customer/BuyerApp.tsx:631` invoking
`customerAppClient.submit()`; in
`src/lib/customerApp/customerAppClient.ts:411` that wrapper invokes the
unquoted `submit_customer_order_v1` RPC. This is an executable customer route,
not merely a Point100 static test.

- Central owner repair: [Central #664](https://github.com/oasisbaklawa2006/Oasis-Baklawa-Central/issues/664)
  and [draft PR #665](https://github.com/oasisbaklawa2006/Oasis-Baklawa-Central/pull/665),
  which migrates web checkout to explicit Core quote approval and quoted submit.
  Its disposable authenticated certification and protected release must pass
  before production legacy RPC access can be revoked.
- Native Buyer owner repair: [Buyer #64](https://github.com/oasisbaklawa2006/oasis-baklawa/issues/64)
  and [PR #65](https://github.com/oasisbaklawa2006/oasis-baklawa/pull/65), which
  removes the old direct call and disallows it in Buyer RPC allowlists.
  Existing installed Android builds may still use the legacy route; staged
  compatibility/update policy must be signed off.
- **Order of operations:** verify/roll out quoted-only clients or explicitly
  fail-close outdated clients; run a protected dry-run of this ACL migration
  and test all legitimate callers; obtain independent owner approval; then
  deploy Core grant restriction under the governed release workflow.
  Releasing this ACL restriction first may cause live Central/old-mobile
  checkout failures. Do not silently regrant authenticated access as an
  automated rollback; that would reopen the same quotation-consent risk.

This is an evidence/documentation correction only. It is **not** evidence
that Central or installed Buyer clients have shipped, or that the Core
migration is live.

## Verification (non-production)

- pgTAP: `supabase/tests/20261101040000_customer_checkout_legacy_submit_quote_consent_barrier_v1.sql` (+ updated checkout regression tests).
- PostgREST (local loopback only): `scripts/tests/verify-customer-checkout-quote-consent-postgrest.sh` → legacy HTTP 403, quoted HTTP 200.

**Release state:** DRAFT PR / HOLD — no production migration, merge, or deploy performed by this agent run.

## Release chronology provenance (Core #488)

This file accompanies the **separately reviewed, clean-based, still-unmerged release-order candidate** for original Core PR #489 (`5b6cec922e209ff9b1f7363d8aa3f7b81c83f5a9`). The same SQL ACL logic is assigned pending version `20261101040000` strictly above current protected Core main (`20261101030000`) and below parked later-version draft migrations. This is a numerical ordering slot, **not** a claim that the change was authored, approved, or deployed on 1 November. Original PR #489 remains an audit source and must not be independently released alongside the replacement. Revalidate protected chronology, production ledger, CI and independent human authorization before merge or rollout.
