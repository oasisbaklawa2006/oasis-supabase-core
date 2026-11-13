# Core #522 protected release preflight — 10 November 2026

Status: NOT production released. No merge, production migration or configuration change is authorized here.

CodeRabbit's c349a4b review found the authentication workflow checked out the default pull-request merge commit. The workflow now explicitly selects the PR head SHA (or push SHA) and verifies the checked-out commit before running tests. This is a CI provenance correction; authentication runtime and migration source are unchanged.

## Index-build release planning

Production read-only census: public.users 167 rows / 245,760 total bytes; public.b2b_applications 58 rows / 172,032 bytes; public.companies 218 rows / 147,456 bytes. This is a point-in-time observation, not an index-build timing guarantee.

Keep the seven transactional CREATE INDEX IF NOT EXISTS statements unchanged. Do not add CONCURRENTLY inside a Supabase migration transaction. For this small current population, use the separately owner-approved protected release in a low-traffic window. Re-read row counts, inspect active/long transactions, retain the existing governed release path, and abort/defer if unexpected lock contention or material growth changes the assessment. Any pre-creation with CONCURRENTLY outside the normal migration path would require separate authorization; none was performed or is authorized by this note.

## Other open gates

- Real MSG91 token and physical Android acceptance remain outstanding. A successful generated Supabase session from a synthetic fixture is not real SMS delivery or device acceptance.
- The reserved-alias guard covers new Auth rows and email changes. Its deferred trigger checks the final row because GoTrue can write email and admin metadata in separate statements. Only a fresh authorization for the exact canonical alias permits the change. The trigger consumes that authorization and preserves other app metadata. Existing inventory has six aliases with confirmed phones.
- The current protected release applies both pending migrations together. The new Edge bundles require the identity RPCs from `20261113124000`. Prepare both bundles before the approved release window, apply the migrations through the protected workflow, and deploy and verify the matching `msg91-otp` and `msg91-session-bridge` bundles immediately afterwards. New alias creation and binding fail closed during the interval between the guard migration and the matching Edge deployments. Existing aliases remain usable under the guard.
- Before production rollout, verify ordinary signup, reserved-alias denial, existing login, admin binding and legacy recovery through hosted Preview Auth. If rollback is needed, remove the trigger through a governed corrective migration before restoring older Edge bundles.
- The #519 transactional Preview is now a separate, owner-approved total-quarantine environment. Its Edge functions intentionally deny business requests; do not use it as a working OTP/AI environment or silently repoint APKs.
- Production integration reports MIGRATIONS_FAILED in the branch registry; successful scoped Preview tests do not certify production release health.

Fresh exact-head CI and independent review are required after the workflow correction. No checks or branch protections were weakened; unattended auto-merge remains off.

## Reserved-alias verification on 11 November 2026

- Supabase applied migration `20261113124100` to Auth Preview `jiocprripcelwujsgwdq`. The deployed `msg91-otp` v99 and `msg91-session-bridge` v13 source bundles match runtime commit `1d57263c9ebc85449b11b74a39428807fd471d57`.
- Hosted GoTrue accepted an ordinary email signup and returned a session. Signup and email change to a reserved alias returned HTTP 500. Postgres logs recorded both alias guard denials and the existing session retained its ordinary email. The synthetic Auth user and its application profile were removed.
- The hosted SQL transaction accepted trusted creation and binding, preserved unrelated metadata, rejected stale or mismatched authorization, and rolled back its fixtures. The same contract passed under the Auth role in scratch PostgreSQL.
- Buyer PR #76 passed CI and CodeRabbit at `41fef7b310f67714a0cecd417c21a61f0b51660e`. EAS CLI reports no authenticated session in the workspace. A Preview APK and real MSG91 device run are pending.
- Preview v99 returned HTTP 403 for each retired outbound mode and HTTP 400 for a missing widget token. The Auth Preview public key passed the Buyer's zero-row Data API probe.
