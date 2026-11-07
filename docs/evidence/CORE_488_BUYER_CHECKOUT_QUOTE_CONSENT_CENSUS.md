# Core #488 — Buyer checkout quote-consent boundary (caller / ACL census)

**Provenance:** `oasis-supabase-core` @ `645899439fe0a84806238b9114649eb2c3785a75` (pre-fix main) with draft enforcement in migration `20261107102000_customer_checkout_legacy_submit_quote_consent_barrier_v1.sql`.

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

## Verification (non-production)

- pgTAP: `supabase/tests/20261107102000_customer_checkout_legacy_submit_quote_consent_barrier_v1.sql` (+ updated checkout regression tests).
- PostgREST (local loopback only): `scripts/tests/verify-customer-checkout-quote-consent-postgrest.sh` → legacy HTTP 403, quoted HTTP 200.

**Release state:** DRAFT PR / HOLD — no production migration, merge, or deploy performed by this agent run.
