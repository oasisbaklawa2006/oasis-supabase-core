# WA-100 UAT-01 — Click2API HTTP 401 and audit-truth recovery

Status: REPAIR PR / NOT DEPLOYED. Canonical certification: Core Issue #450. Incident: Issue #532.

## Evidence — 14 November 2026 (UTC)
- Dedicated consented test marker: `WA100-UAT-01`.
- Inbound persisted and resolved at 10:38:11Z; single stitched packet; AI classified ENQUIRY, Customer Service routing complete.
- Governed reply outbox received provider `HTTP_401` with semantic provider response `token invalidated`; five rejected attempts and `FAILED_FINAL`. No provider message ID, acceptance or delivery timestamp.
- Historical failures showed the same HTTP 401 across 10 prior autonomous outbox rows.
- The legacy `AUTONOMOUS_NON_ORDER_RECEIPT_SENT` case event was emitted immediately following enqueue, before provider acceptance. It was not delivery proof. Immutable historical events remain unchanged.

## Protected changes in this PR
1. `public.fail_whatsapp_operator_reply(...)` treats a definite `HTTP_401` provider rejection as `FAILED_FINAL` on its first occurrence with no retry schedule. It does **not** assume uncertain provider acceptance is rejected; `p_acceptance_unknown=true` continues to stop all retries in `ACCEPTANCE_UNKNOWN`.
2. The non-order governance function writes `AUTONOMOUS_NON_ORDER_RECEIPT_QUEUED` for new queue entries, never `..._SENT` at enqueue. It returns `receipt_enqueued` for successful queueing and a conservative `receipt_sent=false` compatibility field; callers must not treat the latter as confirmed delivery.
3. The test suite verifies retry rejection, transient 503 backoff, unknown acceptance quarantine, secure function boundaries and no premature SENT-event assertion. Legacy replay tests now use the actual enqueue semantics.
4. No historical outbox or audit event is rewritten, released, resent or discarded. Existing provider-accepted IDs remain immutable. This PR does not rotate secrets or send messages.

## Provider administrator action (required; NOT automated)
- Open the Click2API provider dashboard using the authorized admin account.
- Verify whether the bearer/access token associated with `CLICK2API_ACCESS_TOKEN` was revoked, expired or paired with a different account than `CLICK2API_API_KEY`. Check the provider's documented requirements for the send endpoint before changing either credential.
- Issue or refresh the correct credential through the provider. Store values **only** in approved Supabase production secret management; never paste values into GitHub issues, CI logs, ChatGPT or browser code.
- Coordinate with the production operations owner and revalidate the consumer's provider auth without exposing recipient numbers or requesting blind sends. A secrets-name check by itself does not prove token validity.
- Do **not** automatically replay legacy `FAILED_FINAL`, `QUARANTINED` or `ACCEPTANCE_UNKNOWN` rows. All ten historical HTTP_401 failures plus UAT-01 remain terminal. Re-test with a freshly consented dedicated number and a new idempotency key.

## Protected release
- Run clean database replay and pgTAP; CodeRabbit/Cursor/security review; exact-head CI; independent human CODEOWNER review.
- Treat migration `20261114110000_wa100_http401_terminal_and_receipt_enqueue_truth.sql` as a separately approved **database production change**. No direct production SQL or unprotected deploy.
- Capture full function definitions and recovery instructions before applying. Deploy only via approved migration workflow and `supabase-production` authorization, verify migration ledger and effective function definitions afterwards.
- Verify that an auth-rejected test can never produce an ACCEPTED or DELIVERED status, and that the first 401 is immediately terminal.
- After provider auth is repaired, consented end-to-end tests must demonstrate inbound -> AI -> customer-service case -> provider ACCEPTED -> signed delivery callback -> durable DELIVERED/READ. Require a separate staff role/AAL2 and order-authority test suite for WA-100 final certification.

## Certification matrix (current)
| Gate | Verdict |
|---|---|
| Protected privacy webhook v176 deployment + rollback | PASS |
| UAT-01 inbound, stitched message and AI interpretation | PASS |
| Customer-service department routing | PASS |
| Provider send for UAT-01 | FAIL (HTTP_401) |
| Provider delivered/read callback | NOT VERIFIED |
| Accurate SENT event lifecycle | PATCH PROPOSED, NOT DEPLOYED |
| Staff individual ownership and live 36-case UAT | NOT CERTIFIED |
| Full WA-100 launch | NO-GO |

No customer traffic or production data should be mutated solely to make dashboards or certification checks appear green.
