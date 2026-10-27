# Access and consent intake — Grok asks only for missing items, one at a time

## Secure identity/access policy
NEVER ask for or accept a password, OTP, session cookie, API key, Supabase service_role, WhatsApp permanent token, Meta app secret, TOTP seed, recovery codes or sensitive customer list in conversation, a GitHub issue, evidence ledger or Grok transcript. Owner logs in interactively or shares narrowly scoped, expiring access by approved vault/platform UI. Record only credential **reference**, access scope, expiry, approving human and grant status, not its value. No use of another employee's account or identity.

## Non-secret intake order and decision points
1. **Test recipient consent**: Do you control at least one dedicated WhatsApp phone for UAT and explicitly consent to test messages? Record recipient alias (e.g. UAT-CUSTOMER-A), consent timestamp/method and hashed phone inside private restricted system; do not paste number publicly.
2. **Surfaces**: provide Central and Buyer web/app URLs and test build/platform. Are they staging or live? Can Grok actually interact with browser/mobile via an authorized tool, or will you complete clicks/screens and hand back redacted evidence?
3. **Provider**: Click2API/Meta source actually driving your WhatsApp ingress; access to sandbox/provider delivery dashboard; location of signed callback evidence. Give vault integration instructions/ID only, no key.
4. **Test identities**: named *test* users or consented human participants for SALES, CUSTOMER_SERVICE, FINANCE, OPERATIONS/DISPATCH and QA. Access/roles must be granted by the real admin through sanctioned identity management. State who has AAL2; only humans enter OTP and complete second factor.
5. **Fixtures**: non-sensitive mock company, preapproved product SKU+MOQ, sample order with unambiguous numbers, variant with ambiguous names, test PDF, image and voice note; explicit non-billing/no-fulfillment test marker.
6. **Economics & permission**: maximum message sends, channels, rupee cost cap, test window, whether to allow real outbound provider messages to the consenting recipient, cancellation/stop signal, and any provider template requirement. Owner must affirm the exact test plan before live sends.
7. **Reconciliation**: permission to read restricted provider and Core/Central logs (no broad export), and which human will sign the final report.

## Run header (never contains secrets)
```json
{
  "run_id":"WA450-20261027-01",
  "environment":"PRODUCTION_CONSENTED",
  "approval_state":"NOT_APPROVED",
  "owner_approver":"PENDING",
  "recipient_alias":"UAT-CUSTOMER-A",
  "recipient_consented":false,
  "provider_dashboard_access":"NOT_GRANTED",
  "staff_aal2_human":"NOT_ASSIGNED",
  "send_cap":0,
  "budget_inr":0,
  "vault_ref":"NOT_CONFIGURED",
  "window_utc":"PENDING"
}
```

## Stop conditions
Stop on missing consent, no true signed provider event, unauthorized identities, anomalous real customer reach, runaway retries, unsafe payment/order creation, actual order fulfillment, duplicate provider sends, unverifiable message lineage, authentication failures, data leakage or any paid send exceeding the explicit cap. Do not proceed by accepting a textual bot assertion as evidence.