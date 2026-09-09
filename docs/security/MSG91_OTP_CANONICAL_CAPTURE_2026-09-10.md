# MSG91 OTP canonical capture — 2026-09-10

## Authority

This lane closes the `msg91-otp` canonical-source gap identified by the Edge Function production audit and hardens the public verified-session boundary discovered by physical UAT. Backend authority remains `oasis-supabase-core`; Central is the originating application repair only.

## Proven source lineage

- Central issue: `Oasis-Baklawa-Central#561`
- Central repair PR: `Oasis-Baklawa-Central#563`
- Central merged commit: `f7c94ab8984fa82f99e103bf2e8de22298c5d320`
- Initial Central source blob SHA: `9dccb799a1df6f393071a9decd7f838bf8584242`
- Initial Core capture used the same blob SHA, proving byte-identical transfer before Core security review.
- Core PR #269 then applies the additional backend-security findings discovered during canonical review.

## Production boundary

At capture time the live Supabase project `tcxvcatsqqertcnycuop` still serves legacy `msg91-otp` version 72 with source SHA-256 `53854ef59c537f4455db69aa64dbf9e63a19e3ce599c39419b50597047f2040d` and `verify_jwt=false`.

No production change is made merely by this PR. Production rollout has two governed stages and the order is mandatory:

1. merge Core PR #269 only after exact-head migration/Edge/security review is green and explicitly approved;
2. run the protected Core Production Migration Release so `20260910030000_msg91_widget_security_guard.sql` is present in production;
3. verify the guard table/RPC grants and production schema parity;
4. deploy the reviewed Core `msg91-otp` Edge source, preserving `verify_jwt=false`;
5. verify the live Edge source/version and run the fresh-number physical UAT.

The Edge source depends on the new service-role-only guard RPCs and must not be deployed before the migration is production-certified.

## Security repair boundary

Core PR #269 now includes:

- server-verified MSG91 phone as the sole identity authority;
- client/provider phone mismatch rejection;
- duplicate public phone identity rejection before identity writes;
- explicit token-mint failure with no null-token success;
- provider credential sourced only from `MSG91_AUTH_KEY` Edge Runtime secret, with fail-closed configuration handling;
- no raw provider payload/access-token/phone/user-id logging;
- generic fatal client errors;
- cryptographic legacy OTP generation and no OTP value in the HTTP response;
- durable hashed-origin attempt limiting before provider verification;
- durable hashed phone/IP verification windows and atomic one-time access-token claim before identity/session work;
- private replay/rate ledger with SHA-256 digests only and service-role-only RPC authority.

No anonymous B2B application grant or automatic duplicate-identity merge/delete is included. The migration adds only the private security ledger and its two narrow service-role RPCs.

## Credential action

The previously source-embedded provider credential fallback has been removed. If that historical value was a live provider credential, it must be revoked/rotated in MSG91 and the current `MSG91_AUTH_KEY` Edge Runtime secret must contain the replacement before production Edge deployment. Repository code and logs must never expose the replacement value.

## Exit evidence

After the migration and Edge deployment are both production-certified, physical UAT must use a genuinely fresh mobile number and prove:

`Apply for B2B Access -> MSG91 OTP -> authenticated PENDING session -> /customer-app-redirect -> /buyer/access-request -> submission -> internal Pending entry`

Issue #561 remains open until that physical evidence passes.
