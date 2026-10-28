# WhatsApp webhook forward release from the v174 baseline (D1 + D2)

Scope: the protected Edge lane `.github/workflows/whatsapp-webhook-production-release.yml` and its rollback
`.github/workflows/whatsapp-webhook-production-rollback-v174.yml`. This document records the baseline the lane is
pinned to. It does not authorize a deployment.

## Why the lane was repinned

The lane was pinned to live v173 (bundle `53ad71aa519a6a654bf88e8718b08f3a06039b71fa78d28481efd64e1342651c`) and to
the earlier database release (run `40356978870`, SHA `5b268fd8a91e6e8cafd7a48e1f0f79b0861f4e0d`). Production moved on:

| Fact | Value |
|---|---|
| Live `whatsapp-webhook` | ACTIVE, version 174, `verify_jwt=false` |
| Live bundle SHA-256 | `c3fea9d3f817bea59ba5e69b342c44a44d92f1323d3bad171002e06a8a6b8a9e` |
| Database prerequisite run | `40670202741` (Production Migration Release, success) |
| Database prerequisite SHA | `387c1b573aa0dae2d06db303089fa5c21f662a99` |
| Database prerequisite artifact | `production-migration-deployment-387c1b573aa0dae2d06db303089fa5c21f662a99` |

A `deploy=false` preflight (run `40688668042`, main `387c1b57`) failed at "Pin current live webhook baseline", which is
the intended fail-closed behavior when the live function is not the version the lane was built for. Nothing deployed.

## What changed

- Forward release pins: `EXPECTED_LIVE_VERSION "174"`, `EXPECTED_LIVE_BUNDLE_SHA c3fea9d3...`, and the three
  `DB_PREREQ_*` values above.
- The pre-deploy rollback capture is now the v174 source: `whatsapp-webhook-predeploy-v174.tar.gz`,
  `...-source-manifest.json`, `...-archive-files.txt`.
- New rollback lane `whatsapp-webhook-production-rollback-v174.yml`: identical design to v173, restoring version 174
  and bundle `c3fea9d3...`. Its unauthenticated-POST smoke accepts only the measured v174 profile
  (`401 signature_missing`).
- Historical rollback lanes (v167, v168, v173) are unchanged and still consume the artifacts of the older releases.
- Governance guard `scripts/check-whatsapp-webhook-production-release.sh` and its regression test assert the new pins,
  the new lane, and reject stale v173 pins in the forward lane.

## Not changed on purpose

- The packet-AI worker and consumer production release lanes and their pins.
- `.github/workflows/wa461-certification-controller.yml`. Its deploy auto-dispatch is bound to merged PR #463 and its
  head branch, so merging this change does not dispatch a deployment. Its observer job is also bound to #463 and
  version 173; it will not certify a release from this lane. Widening it needs a separate owner decision.

## Release procedure (all gates remain)

1. Merge this change through review with an independent human approval.
2. Dispatch the release workflow with `deploy=false`, `certify_existing=false`, `release_sha=<exact merged main SHA>`.
   It must pass, including "Pin current live webhook baseline".
3. Only with the owner's explicit instruction, dispatch `deploy=true` with the same SHA. The deployment job runs in the
   `supabase-production` environment and waits for its approval. It captures the restorable live v174 source first.
4. After deployment verify: live version greater than 174 and the new bundle SHA; reviewed and deployed source closures
   equal; the rollback artifact present; unauthenticated probes 403 / 401 `signature_missing` / 204 with no CORS header;
   no credential material in evidence; runtime health and logs.

Merging or deploying is not WhatsApp certification. Live provider UAT, consent, AAL2 staff evidence and independent
sign-off remain separate gates.
