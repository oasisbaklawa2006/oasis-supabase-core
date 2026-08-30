# PR #148 file classification (Command 8 cleanup)

Audit of the pre-cleanup `cursor/wa-stage1b-execution-256d` branch (44 commits / 46 files).

## Retained in narrow evidence PR

| Path | Classification |
| --- | --- |
| `artifacts/wa-stage1b-cert/report.json` | STAGE1B_CERT_EVIDENCE |
| `docs/cert/STAGE1B_PASS_EVIDENCE.md` | STAGE1B_CERT_EVIDENCE |
| `docs/cert/PR148_FILE_CLASSIFICATION.md` | STAGE1B_CERT_EVIDENCE |
| `scripts/whatsapp-stage1b-cert/run.ts` | STAGE1B_CERT_HARNESS |
| `scripts/whatsapp-stage1b-cert/generate_fixtures.py` | STAGE1B_CERT_HARNESS |
| `scripts/whatsapp-stage1b-cert/fixtures_manifest.json` | STAGE1B_CERT_HARNESS |
| `scripts/whatsapp-stage1b-cert/bundled/24-audio-order.mp3` | STAGE1B_CERT_HARNESS |
| `supabase/functions/_shared/stage1bCert/**` | STAGE1B_CERT_HARNESS |
| `supabase/functions/whatsapp-stage1b-cert-runner/**` | STAGE1B_CERT_HARNESS |

## Removed — already canonical elsewhere

| Path | Classification | Canonical home |
| --- | --- | --- |
| `.github/workflows/sync-preview-cert-edge-secrets.yml` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/config.toml` `[edge_runtime.secrets]` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/PREVIEW_EDGE_SECRETS.md` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `scripts/check-preview-edge-runtime-secrets-*.sh` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `scripts/resolve-preview-gemini-credential.sh` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `scripts/resolve-production-gemini-secret.py` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/functions/_shared/geminiProvider.ts` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/functions/_shared/geminiProvider.test.ts` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/functions/whatsapp-packet-ai-worker/index.ts` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `supabase/functions/whatsapp-content-interpret/**` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `scripts/check-whatsapp-gemini-retry-contract.sh` | ALREADY_CANONICAL_ELSEWHERE | PR #147 / main |
| `.github/workflows/edge-function-governance.yml` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |
| `docs/runbooks/WA7_WHATSAPP_RELEASE_CERTIFICATION.md` | ALREADY_CANONICAL_ELSEWHERE | PR #147 |

## Removed — required defect fixes (land via #147, not evidence PR)

| Path | Classification | Notes |
| --- | --- | --- |
| `supabase/functions/_shared/whatsappGovernedMediaFetch.ts` | REQUIRED_STAGE1B_DEFECT_FIX | PR #147 |
| `supabase/functions/_shared/whatsappGovernedMediaFetch.test.ts` | REQUIRED_STAGE1B_DEFECT_FIX | PR #147 |
| `supabase/functions/_shared/studioInboxFanOut.ts` | REQUIRED_STAGE1B_DEFECT_FIX | PR #147 |
| `supabase/migrations/20260830120001_wa_stage1b_unclear_clarification_autonomy.sql` | REQUIRED_STAGE1B_DEFECT_FIX | PR #147 |
| `supabase/tests/20260830120001_wa_stage1b_unclear_clarification_autonomy.sql` | REQUIRED_STAGE1B_DEFECT_FIX | PR #147 |

## Removed — unrelated / accidental branch contamination

| Path | Classification | Canonical home |
| --- | --- | --- |
| `supabase/migrations/20260830100000_pre_factory_credit_wallet_authority.sql` | UNRELATED_OTHER_MODULE | **main** (#141) |
| `supabase/tests/20260830100000_pre_factory_credit_wallet_authority.sql` | UNRELATED_OTHER_MODULE | **main** (#141) |
| `supabase/migrations/20260830100500_wa_core_c_canonical_clarification_disclosure.sql` | UNRELATED_OTHER_MODULE | **main** (#144) |
| `supabase/tests/20260830100500_wa_core_c_canonical_clarification_disclosure.sql` | UNRELATED_OTHER_MODULE | **main** (#144) |
| `supabase/migrations/20260830101000_trace_printer_settings_authority.sql` | UNRELATED_OTHER_MODULE | **main** (#145) |
| `supabase/tests/20260830101000_trace_printer_settings_authority.sql` | UNRELATED_OTHER_MODULE | **main** (#145) |
| `docs/runbooks/WA_E2E_MISSION_CONTROL_AUDIT.md` (full branch delta) | ACCIDENTAL_BRANCH_CONTAMINATION | Mission Control updates belong on audit branch, not cert evidence |
| `docs/security/EDGE_FUNCTION_REGISTRY_CONFIG_RECONCILIATION_2026-07-31.md` | ACCIDENTAL_BRANCH_CONTAMINATION | Registry doc churn from unrelated merges |
| `scripts/check-edge-registry-config-reconciliation.sh` | ACCIDENTAL_BRANCH_CONTAMINATION | Unrelated to Stage 1B evidence |
| `.gitignore` protected-corpus lines | ALREADY_CANONICAL_ELSEWHERE | Present on main via prior cert work |

No legitimate work was deleted; unrelated migrations already exist on `main` via merged PRs #141, #144, #145.
