# WA-100 — Meta Direct Send utility contract preparation (SOURCE ONLY)

**Status:** Candidate pure offline contract only. No HTTP client, Supabase secret, runtime switch, SQL, Edge deployment, customer message or provider migration is introduced by this change. The corresponding function file is **not imported by any production function**. Do not claim completion or Meta production activation from a passing test.

## Evidence and separation

- Owner supplied Meta WhatsApp Manager screenshot confirming **Oasis Baklawa Central eligible for Direct Send** and vendor channel page has now changed the action label to **"Disable WhatsApp Direct"**. Another stale browser tab still showed "Enable"; this is provider UI configuration evidence, **not proof of a successful Direct Send API call**.
- The owner supplied Meta's official text message syntax: `POST /<WHATSAPP_BUSINESS_PHONE_NUMBER_ID>/messages`, `messaging_product=whatsapp`, `recipient_type=individual`, `to`, `type=text`, `text.body`, and `category=utility`. Body limit 1,024 characters. Direct Send utility and Direct Send authentication (restricted alpha) are distinct.
- Marketing Messages Lite (MM Lite, renamed Marketing Messages API in some Meta docs) is a **separate marketing delivery route**, not required to build the utility-only Direct Send request. **Do not click "Upgrade to MM Lite"** as part of this certification lane.
- Current Core production uses the **separate** Click2API CRM `POST https://crm.click2api.in/api/v1/messages` route; 13 prior terminal HTTP_401 and 77 queue-only accepted outbox records still need authoritative CRM credential and queue-to-wamid contract. Do not assume provider-side "Enable WhatsApp Direct" repairs those historical failures.
- A previously consented dashboard authentication template and a separate utility template produced Meta `wamid` events seen by the Core webhook; these were `provider_status_unmatched` because there was no originating governed Core row.

## Offline contract

`supabase/functions/_shared/whatsappMetaDirectSendUtility.ts` exports only:

1. `buildMetaDirectSendUtilityText`: explicit governed *purpose label*, strict E.164 recipient, nonempty text of at most 1,024 UTF-16 code units, fixed category `utility`. No marketing, service or authentication request can be constructed through the typed contract. The label alone **does not certify message content as utility**.
2. `readMetaDirectSendAcceptance`: extracts a single authentic-shaped `wamid.` from a single Meta acknowledgement, preserves `accepted` / `held_for_quality_assessment` / `unspecified` submission status; rejects queue UUID, error payloads, malformed IDs and mixed batches. A message submission acknowledgement is NOT a `SENT` or `DELIVERED` receipt.

The offline GitHub workflow explicitly forbids provider fetch, credentials, network and runtime integration and runs syntax, lint, contract and negative tests. This source does not execute from a deployed function.

## Required before any runtime transport PR

1. Independently verify the account's **actual** Direct Send availability, effective Graph API version and token/app permissions for this WhatsApp phone number, without exposing tokens. Distinguish Meta Graph API, Click2API proxy `/api/meta`, and Click2API CRM V1/V2. Do not infer route semantics from URL names.
2. Establish service-authorized, consented, transactional **UTILITY** message policy; validate order authority, company identity, verified recipient ownership, approved content, template/category policy, opt-outs, quiet hours, throttling and cost. An internal purpose string alone cannot prevent utility-category misclassification.
3. Build a separate named-function, **default disabled** Meta transport adapter behind governed durable single-send claim. Harden against duplicate invocation, network timeouts, acceptance-unknown, rate limits, Meta pacing and failure `135000`, webhook authentication/receipt reconciliation, least-privilege secret scopes and incident isolation.
4. Source-only tests + clean replay/pgTAP where DB contract changes; negative fixtures for missing permissions, invalid message shapes, opted-out recipients, unknown acceptance, duplicate claims, 401/403/429, retries, pacing/failed status and callback attribution. No automatic fallback to Click2API or MSG91 if Meta acceptance is unknown.
5. Obtain new independent CODEOWNER and security review, all protected exact-head checks, immutable recovery bundle, independently approved `supabase-production` named deployment, explicit consented test recipient and release/rollback owner. Do **not** move historical failed or quarantined messages into the new lane.
6. Certify one **Core-originated** consented send with persisted exact `wamid` and callback-linked `DELIVERED` (and prove zero duplicate sends); continue the separate Central signed-in no-send UAT.

## Explicit NO-GO

- **No** release or activation from this PR.
- **No** credential rotation, secret copying, CRM version change, Meta re-registration, MM Lite onboarding, or Click2API queue clearing.
- **No** mixing marketing into `category: utility`; no OTP activation just because utility Direct Send is eligible.
- **No** production claims of end-to-end delivery until Core-originated trace is proven.

This contract may be independently reviewed and source-merged under Core branch protection, but the WA-100 runtime and final certification status remains NO-GO.
