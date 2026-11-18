# WA-100 — protected retirement of legacy WhatsApp OTP (Core #538)

**Status:** PROPOSED SOURCE CANDIDATE — not deployed. No change to the live function is implied by this document.

## Exact production target and observed risk
- Project `tcxvcatsqqertcnycuop` (Oasis Baklawa Core production).
- Existing function `whatsapp-otp` v115: ACTIVE, verify_jwt=false, historical Central-origin source.
- Live source used `Math.random()`, plaintext `wa_otp_` setting records, unauthenticated OTP verification, and Auth user/session issuance. Core DB RLS issue #538 and Core protected policy PR #541 are separate.
- Canonical Central frontend uses `msg91-otp` for current Buyer login; organization-wide source search found no direct frontend invocation of `whatsapp-otp`. **This does not establish there are no external/mobile clients.**

## What is in the candidate
`supabase/functions/whatsapp-otp/index.ts` is a non-mutating HTTP 410 response with no provider calls, database access, token generation, request parsing, CORS or auth-session creation. No new secret or project-wide config change.

## Fail-closed controlled sequence
1. Independent Central/Buyer App owner confirms `whatsapp-otp` is unused in active Android, iOS, browser and staff login; if any legacy client remains, migrate it through the authorized MSG91 path first.
2. Execute candidate Deno tests, security review, CODEOWNER approval, repository required checks and exact-SHA diff review. Never bypass protected branch or `supabase-production` environment.
3. Before deploy, capture live v115 source closure, metadata, verify_jwt posture, invocation logs and recovery evidence in access-controlled artifacts. Obtain second-person production release authorization.
4. Deploy **only** named `whatsapp-otp` from exact reviewed Core SHA using a separately approved protected workflow that explicitly sets `verify_jwt=true`. Do not execute an ungoverned CLI command or direct Supabase function mutation.
5. Read back live version >115, `verify_jwt=true`, and exact source closure. Verify anonymous calls fail at the gateway; authorized calls return 410 and emit no OTP, provider message, Auth user or settings write. Validate MSG91 Buyer Auth in a dedicated UAT with preserved identity/company associations.
6. Confirm Core PR #541's OTP-RLS migration is applied through its independently approved `Production Migration Release`, with sensitive rows blocked for ordinary authenticated and admin identities. Retain service-only cleanup.
7. Review rollback without automatically restoring vulnerable v115. For functional recovery, prefer the separately authorized MSG91 login path; restoration of old OTP code is **not** an acceptable default rollback.

## Non-goals
No Click2API API key rotation, no unsolicited customer messaging, no historical outbox replay, no production data deletion, no bypass of auth or CODEOWNER review. The P0 legacy function is an independent security issue, not the established root cause of the Click2API HTTP 401 regression.

## Evidence / tracking
Core #538, Core PR #541, WA master #450, separated Central non-authoritative attempt #672 (superseded under Core backend ownership).
