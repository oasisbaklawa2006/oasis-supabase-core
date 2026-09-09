# MSG91 OTP canonical capture — 2026-09-10

## Authority

This capture closes the `msg91-otp` canonical-source gap identified by the Edge Function production audit. Backend authority remains `oasis-supabase-core`; Central is the originating application repair only.

## Proven source lineage

- Central issue: `Oasis-Baklawa-Central#561`
- Central repair PR: `Oasis-Baklawa-Central#563`
- Central merged commit: `f7c94ab8984fa82f99e103bf2e8de22298c5d320`
- Central source path: `supabase/functions/msg91-otp/index.ts`
- Exact source blob SHA: `9dccb799a1df6f393071a9decd7f838bf8584242`
- Core captured path: `supabase/functions/msg91-otp/index.ts`
- Core captured source blob SHA: `9dccb799a1df6f393071a9decd7f838bf8584242`

The equal blob SHA proves the Core capture is byte-identical to the reviewed and merged Central repair.

## Production boundary

At capture time the live Supabase project `tcxvcatsqqertcnycuop` still serves legacy `msg91-otp` version 72 with source SHA-256 `53854ef59c537f4455db69aa64dbf9e63a19e3ce599c39419b50597047f2040d` and `verify_jwt=false`.

This commit does not deploy or mutate production. Production deployment must use the reviewed Core source after Core merge and must preserve `verify_jwt=false`, because this is an established public OTP/provider-verification endpoint using its own provider verification flow.

## Repair boundary

The captured repair hardens the verified-session handoff by making the server-verified MSG91 phone authoritative, rejecting conflicting/duplicate identity ownership, failing closed on token-mint errors, removing raw provider payload disclosure, and preventing null-token success responses. No database migration, schema mutation, anonymous B2B application grant, or automatic duplicate-identity merge/delete is included.

## Exit evidence

After governed production deployment, physical UAT must use a genuinely fresh mobile number and prove:

`Apply for B2B Access -> MSG91 OTP -> authenticated PENDING session -> /customer-app-redirect -> /buyer/access-request -> submission -> internal Pending entry`

Issue #561 remains open until that physical evidence passes.
