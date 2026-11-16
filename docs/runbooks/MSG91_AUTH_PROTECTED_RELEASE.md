# Core #521 — MSG91 dual-Edge protected production release

Date: 16 November 2026. **Source-only, unmerged and NOT deployed.**

## Authority and exact scope

Canonical Core repository only. The named production Edge functions are `msg91-otp` and `msg91-session-bridge` in Supabase Core `tcxvcatsqqertcnycuop`. No Central, Buyer, WA-100, checkout, payment, schema or Edge secret change is authorized by this runbook.

Observed LIVE baseline (read-only Supabase function inventory on 16 Nov 2026):

| Function | Live version | Immutable live bundle SHA-256 | JWT mode |
| --- | ---: | --- | --- |
| msg91-otp | 89 | `b98fddff3fc54d07b2df2636817932522e0a734cbe17ad38f8539ebcea114380` | false |
| msg91-session-bridge | 9 | `1850019b03bc96f7dcfd584e0aa0a60b4c5a758954f2757ea620f9105d0f0a94` | false |

Core #530 was already merged and its three migrations exist in the production ledger, but its Edge sources have **not** been deployed. The v89 OTP function still accepts legacy outbound modes, so Core #521 remains a P0 production security hold.

## Prerequisites before a production release

1. This workflow source, target source closure, production metadata pins, rollback plan and customer-compatibility mapping receive **independent** security/CODEOWNER review. All exact-head CI and CodeRabbit/Codacy/Copilot findings must be resolved.
2. A separately approved **dedicated nonproduction** Buyer/Auth/MSG91 Preview must have canonical Core migration replay, actual GoTrue state, provider-credential isolation and synthetic tenants. It must pass invalid/replayed/revoked OTP, legacy 403/no-outbound, reserved-alias and duplicate identity tests. Buyer #64/PR #76 and Core #495 track this; green source CI and a reused historical Preview do NOT satisfy this gate.
3. Owner must confirm the MSG91 widget and session bridge clients (current Android, browser and any active legacy clients) do not rely on retiring `login_otp`/`order_received`; protect legitimate existing login and account recovery. Provider sends are disabled/test isolated during Preview acceptance. No real recipient test without a separately approved plan.
4. Capture specific exact-head UAT run, signed artifact ID, failure/rollback rehearsal, approved release window, monitoring owner, and independently authorized production environment reviewer.
5. Production baseline MUST still be v89/v9 with both exact pinned bundle hashes. Drift means **stop and revise the reviewed release**, not bypass or dynamically retarget a newer bundle.

## Execution sequence

- **Read-only preflight:** dispatch `.github/workflows/msg91-auth-protected-release.yml` from current protected `main`, set `deploy=false` and pass current exact 40-character SHA. `supabase-production-readonly` checks current main equality and both live hashes, validates source-only deny/bridge tests, and captures **separate full live rollback archives**. This may be done without changing production.
- **Protected deployment:** only after the above prerequisites are evidenced, dispatch the **same exact current main SHA** with `deploy=true`, `buyer_auth_uat_approved=true`, `owner_compatibility_approved=true`. The independent `supabase-production` environment approval must be supplied by a human. The workflow rechecks current main, archived checksums and both live pinned baselines **after approval**, then deploys the OTP source FIRST, verifies its downloaded source closure, and deploys the session bridge SECOND.
- **Postdeployment:** both exact sources must match immutable reviewed import-closure SHA-256; each live version must increase and remain `verify_jwt=false` as required by the published widget/bridge protocol. Collect deployed metadata, Source attestation, Android login, invalid OTP/no-send and sessions/claims negative evidence. The workflow deliberately does **not** send a live OTP to an actual recipient or claim device certification.
- **Partial failure:** if OTP deploy succeeds but its readback or bridge deployment fails, halt. The rollback archives are evidence, **not automatic permission to redeploy vulnerable v89**. Escalate as a P0 protected incident; decide safe forward repair or separately approved rollback with independent security approval, and preserve logs before any further production mutation. Failure must not be marked certified.
- **Cleanup:** retain archives and immutable preflight/result artifacts 90 days; reconcile source and version to Core #521, Buyer #64 and canonical release ledger. Never close these issues from a source merge alone.

## Invariant guards

No `supabase db push/reset`, migration repair, secret mutation, broadcast, or broad `supabase functions deploy` operation. The workflow is intentionally **not triggered for production deployment from pull_request**. Default `deploy=false`, exact-current-main binding, strict two-function names, fixed bundle baselines, fail-closed source manifests, offline tests and second-person protected environments are mandatory. New deployment-cost authorization is not implied by this source-only PR.
