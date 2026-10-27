# Acceptance, defect, and sign-off criteria

## Evidence ranking (strongest for live provider)
- **PROVIDER_SIGNED:** genuine provider-authenticated callback with hashed message ID, original source and timestamp; recipient opted in; no token stored. Required for provider delivery/failed/mixed-case certification.
- **PROVIDER_DASHBOARD:** approved provider account read-only receipt for exactly that consenting fixture message, matched to Core state by hashed correlation.
- **DB_READONLY:** safe aggregate or hashed-id query; verify no cross-client exposure and no raw PII export.
- **APP_VISIBLE:** screenshot/video/interaction from authorized user account with timestamp, role and redacted customer identifiers.
- **HTTP_NEGATIVE:** signed-off 403/401/204 rejection proofs; does NOT count as provider delivery.
- **HUMAN_ATTESTED:** named eligible human acceptance, especially consent and MFA; no OTP retained.
- **CI/SIMULATED:** useful for regressions; cannot replace real provider AAL2 or human signoff.

## Mandatory stop/go gates
| Gate | Condition to proceed | Failure handling |
|---|---|---|
| G0 baseline | v174, SHA, SQL migration and rollback independently verified | stop if drift |
| G1 consent | owner-approved allowlist of test phone aliases, send quota/cap, test window, scoped identities and verified AAL2 | stop before any live send |
| G2 security | unsigned callbacks reject, no browser CORS, no leak | stop on 2xx for unauthenticated traffic |
| G3 inbound | signed, consenting inbound message visible through provider -> Core -> case/UI; no invented SKU/qty | log failure, pause unsafe flow |
| G4 outbound | exactly one approved outbound attempt per unique fixture, real delivery/failed/mixed/dedup proof | block final signoff |
| G5 staff journey | authorized tester verifies support, sales, finance, dispatch and AAL2; no unauthorized order/dispatch | block signoff; only human AAL2 |
| G6 operations | current task owners/backlog addressed, historical dead-letter disposition reviewed, zero unexplained loss | do not bulk close or requeue |
| G7 final | 36/36 mandatory cases evidence-linked, independent human owner reviews, no critical defects | only then recommend human final signoff |

## Defect template
`DEFECT-ID`, discovered-at UTC, case ID, actor alias, approved environment, preconditions, exact steps, expected vs observed, request correlation hash, provider event evidence ref, screenshot/log hash, severity S0-S3, potential customer effect, required owner, corrective PR, approval/rollback dependency, exact retest ID and result. Redact PII. No bug should be fixed via unreviewed production patches.

## Daily stop conditions
Immediately halt test traffic for any unexpected real customer recipient, paid threshold exceeded, double-send, unverified identity, bypass of AAL2, user order committed inadvertently, privacy leak, unbounded provider retries, failed webhook verification, or unexplained 5xx increase. Only owner may approve resume after documented corrective action.

## End-of-run certificate (Grok fills, never fabricates)
`VERDICT: PASS | FAIL | BLOCKED | CONDITIONAL`; Core commit; live Edge version/bundle; project; test run ID; case coverage; exact failed/blocked IDs; evidence root hash; provider-signed test IDs and statuses; AAL2 attestation; real outbound attempts and provider receipts; inbound/duplicate/mixed-event 0-loss proof; task and deadletter disposition; budget compliance; zero unauthorized sends; rollback package reference; independent reviewer signature/time. Store confidential evidence privately; post redacted summary to issue #450.

If legitimate provider account or a consented phone cannot be accessed, state `BLOCKED — PROVIDER ACCESS/CONSENT`; do not convert fixture outputs into production evidence.