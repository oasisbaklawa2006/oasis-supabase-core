# Catalogue AI-copy — protected release, review, and recovery

**Scope:** one named Supabase Edge Function only, `catalogue-ai-copy`. This
runbook never authorizes arbitrary Edge deployments or Production migrations.

## Source authority and environment

- Core `main` must contain the merged, independently reviewed `ai_studio.ai.use`
  authorization guard (Core PR #479); use the exact *current main* commit SHA.
- The workflow **MUST** be dispatched on `main`. Do not dispatch an unreviewed
  workflow copy from a feature branch.
- Before any `deploy=true` dispatch, independently confirm that the effective
  GitHub Environment `supabase-production` requires independent human reviewer
  approval, excludes self-review and disallows deployment from non-main refs.
  Keep `SUPABASE_ACCESS_TOKEN` in environment scope, never PR/repo-level.
  If any setting cannot be independently verified, stop release.
- The Production project is `tcxvcatsqqertcnycuop`. Record actual baseline
  version `44` and bundle digest
  `3e428098386b9d07aac360ae3e7955fa20fe4ab90fbe0ff14a6df43e4d6a1ffe`.
- Before rollout, confirm that the source environment contains the correct
  `AI_STUDIO_ALLOWED_ORIGIN`, internal staff RPC, and permission RPC. A Preview
  readiness check is **not** the authenticated allow/deny/revoke/503 UAT.
- The Production AI configuration is under an independently approved change
  **freeze** covering preflight, human environment approval, write and validation.
  In addition to `AI_STUDIO_AI_ENABLED=false`, this security-only release
  requires `OPENAI_API_KEY` to be absent. The workflow checks the Production
  secret inventory at preflight, immediately before the write and after.
  An unreadable/redacted disabled flag, an existing provider key, or an
  unverifiable configuration freeze is a **NO-GO**. The workflow never
  changes secrets. Do not remove Production credentials without separate
  authorization. External administrator/dashboard secret writes cannot be
  prevented by this GitHub workflow alone; administrators must enforce the
  change freeze via independently controlled access restrictions.
- Do not enable or test paid provider calls during this rollout.

## Two-run, archive-bound review

1. Dispatch `Catalogue AI Copy Protected Production Release` from protected
   `main` with `release_sha` equal to its exact SHA and `deploy=false`.
   This only runs contract checks and read-only v44/source preflight.
2. Review the resulting GitHub artifact and job summary. Record **all three**:
   the successful prior `run_id`, the returned `artifact_id`, and the
   SHA-256 digest of `live-v44-rollback.tar.gz`. The artifact captures a full
   restorable v44 source closure. Any live version change during capture fails.
3. Confirm authenticated Preview staff-with-permission denial-of-spend 503,
   no-permission 401, and revoked-permission 401 evidence, using sanitized
   responses only. Confirm AI-disabled configuration and change freeze.
4. Obtain independent release owner approval of **that exact prior run,
   artifact ID and archive SHA-256**, plus the Production environment controls.
5. Only then dispatch a **separate** run on current main with `deploy=true`,
   the prior approved run/artifact/digest, and all Boolean attestations true.
   The workflow rechecks main, live v44 version/hash/JWT, recomputes the
   fresh rollback/source manifest, validates immutable prior artifact ownership,
   compares the two manifests and SHA-256, and rechecks no-spend secrets.
6. Approve the `supabase-production` Environment only after inspecting the
   correct current run's evidence. Never bypass or auto-approve this gate.
7. The single-function write is permitted only after all evidence checks pass.
   It then verifies a newer version, JWT enabled, exact deployed two-file
   source parity, no-spend inventory and 401 rejections. Authorized 503
   runtime UAT must be separately recorded before mission certification.

## Post-write failure and recovery

A GitHub Actions job failure does **not** revert an already deployed function.
Do **not** blindly rerun `deploy=true`; the pinned v44 guard intentionally
refuses a second rollout when the live version is no longer v44.

1. Use `verify_existing=true`, `deploy=false`, the same exact current-main
   `release_sha`, and the original deployment `source_deployment_run_id`.
   This is read-only and verifies the current active function, source parity,
   JWT, source-run provenance, no-spend configuration and rejection responses.
2. If verification succeeds, retain its sanitized evidence and complete the
   separate valid-staff 503 acceptance. If it fails or the deployed code
   mismatches, place the function in incident/NO-GO status, do not enable AI,
   and preserve all original preflight and deployment evidence.
3. Restore v44 **only through a separately approved, manually invoked,
   `supabase-production`-environment protected named-function rollback**,
   after review of the exact current live version/hash and approved immutable
   source preflight artifact, ID, run provenance and SHA-256. The protected
   restore must verify the archive manifest/contents and perform a
   single-function `catalogue-ai-copy` redeploy with `verify_jwt=true`,
   then verify source parity and 401 denial; no migration/secret writes.
   If no approved rollback workflow exists for that incident, open a
   protected rollback PR; **never use a direct Dashboard/API deployment
   or an unreviewed GitHub job** to work around the gate.
4. Any deployment that occurs while the owner configuration freeze cannot
   be assured is an incident requiring explicit review.

## Certification and closure

A merged release-workflow PR merely makes the manual tool available.
Production deployment, human Preview UAT, post-deploy valid-staff 503,
independent Environment approval, and separate business approval for
future paid AI activation remain distinct gates. Do not claim closure until
the deployed source and evidence are verified.
