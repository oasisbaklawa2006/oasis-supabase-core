# Core #522 protected release preflight — 10 November 2026

Status: NOT production released. No merge, production migration or configuration change is authorized here.

CodeRabbit's c349a4b review found the authentication workflow checked out the default pull-request merge commit. The workflow now explicitly selects the PR head SHA (or push SHA) and verifies the checked-out commit before running tests. This is a CI provenance correction; authentication runtime and migration source are unchanged.

## Index-build release planning

Production read-only census: public.users 167 rows / 245,760 total bytes; public.b2b_applications 58 rows / 172,032 bytes; public.companies 218 rows / 147,456 bytes. This is a point-in-time observation, not an index-build timing guarantee.

Keep the seven transactional CREATE INDEX IF NOT EXISTS statements unchanged. Do not add CONCURRENTLY inside a Supabase migration transaction. For this small current population, use the separately owner-approved protected release in a low-traffic window. Re-read row counts, inspect active/long transactions, retain the existing governed release path, and abort/defer if unexpected lock contention or material growth changes the assessment. Any pre-creation with CONCURRENTLY outside the normal migration path would require separate authorization; none was performed or is authorized by this note.

## Other open gates

- Real MSG91 token and physical Android acceptance remain outstanding. A successful generated Supabase session from a synthetic fixture is not real SMS delivery or device acceptance.
- The reserved-alias guard covers new Auth rows and email changes. Its deferred trigger checks the final row because GoTrue can write email and admin metadata in separate statements. Only a fresh authorization for the exact canonical alias permits the change. The trigger consumes that authorization and preserves other app metadata. Existing inventory has six aliases with confirmed phones.
- Release sequence for the alias guard: deploy and verify the matching `msg91-otp` and `msg91-session-bridge` bundles before applying migration `20261111041631`. Those bundles can run with the prior schema. Applying the guard first would block verified provisioning by older bundles. Use the protected release process for both steps.
- Before production rollout, verify ordinary signup, reserved-alias denial, existing login, admin binding and legacy recovery through hosted Preview Auth. If rollback is needed, remove the trigger through a governed corrective migration before restoring older Edge bundles.
- The #519 transactional Preview is now a separate, owner-approved total-quarantine environment. Its Edge functions intentionally deny business requests; do not use it as a working OTP/AI environment or silently repoint APKs.
- Production integration reports MIGRATIONS_FAILED in the branch registry; successful scoped Preview tests do not certify production release health.

Fresh exact-head CI and independent review are required after the workflow correction. No checks or branch protections were weakened; unattended auto-merge remains off.
