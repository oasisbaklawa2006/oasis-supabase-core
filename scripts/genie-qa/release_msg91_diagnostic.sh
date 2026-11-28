#!/usr/bin/env bash
set -euo pipefail
umask 077
QA_REF=skhpmltfjgqitntkmclb
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$RUNNER_TEMP/genie-qa-msg91-diagnostic"
die() { printf 'GENIE_QA_DIAGNOSTIC_DENIED: %s\n' "$1" >&2; exit 1; }
[[ "${GITHUB_REPOSITORY:-}" == oasisbaklawa2006/oasis-supabase-core && "${GITHUB_REF:-}" == refs/heads/main && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
   "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ && "${GITHUB_SHA:-}" == "$EXPECTED_SHA" && "${QA_MODE:-}" =~ ^(preflight|deploy)$ &&
   "${QA_CHANGE_REFERENCE:-}" =~ ^Core#495/Buyer#64\;QA-EDGE-APPROVAL=[A-Za-z0-9._/-]{6,128}$ &&
   -n "${SUPABASE_ACCESS_TOKEN:-}" && -n "${GH_TOKEN:-}" ]] || die scope
if [[ "$QA_MODE" == deploy ]]; then
  [[ "${QA_APPROVAL:-}" == AUTHORIZE-GENIE-QA-MSG91-DIAGNOSTIC ]] || die authorization
else
  [[ -z "${QA_APPROVAL:-}" ]] || die authorization
fi
assert_main() {
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_SHA" &&
     "$(gh api repos/oasisbaklawa2006/oasis-supabase-core/git/ref/heads/main --jq .object.sha 2>/dev/null)" == "$EXPECTED_SHA" ]] || die main_moved
}
api() {
  curl --fail --silent --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$QA_REF/$1" > "$2" 2>/dev/null || die management_read
}
inventory() {
  api secrets "$WORK/secrets.json"
  python3 "$ROOT/scripts/genie-qa/verify_qa_real_provider_secret_inventory.py" "$WORK/secrets.json" || die secret_inventory
  api functions "$WORK/functions.json"
  python3 "$ROOT/scripts/genie-qa/sanitize_gateway_failure_inventory.py" "$WORK/functions.json" "$WORK/current-inventory.json" || die inventory_metadata
  jq -e 'map(.slug)==["buyer-login-gateway","msg91-otp","msg91-session-bridge"] and all(.[]; .status=="ACTIVE" and .verify_jwt==false)' "$WORK/current-inventory.json" >/dev/null || die inventory
  jq -e 'any(.[]; .slug=="buyer-login-gateway" and .version>=2 and .ezbr_sha256=="ebb2a2615f9045e2a71b9a9a0c9e1cba7e503523da1812643e7791e1b3dc0398") and any(.[]; .slug=="msg91-session-bridge" and .version>=8 and .ezbr_sha256=="47c64fb7996548e59301cff7bfe2886a9e06a3bb41b0ff168676abfd8c0d5ee3")' "$WORK/current-inventory.json" >/dev/null || die sibling_drift
  jq -S '[.[]|select(.slug!="msg91-otp")]' "$WORK/current-inventory.json" > "$WORK/current-siblings.json"
  jq -S '.[]|select(.slug=="msg91-otp")' "$WORK/current-inventory.json" > "$WORK/current-otp.json"
}
baseline() {
  jq -e '.version>=8 and .ezbr_sha256=="a19212561ed28d2365d46b04c51309fd72c69bdbfe4dfbcd3df32bcc20cfbb29"' "$WORK/current-otp.json" >/dev/null || die otp_baseline_changed
}
closure() {
  python3 "$ROOT/scripts/edge-function-source-manifest.py" "$1/supabase/functions" msg91-otp --output "$2" || die source_manifest
}
download() {
  mkdir -p "$1/supabase/functions"
  printf 'project_id = "skhpmltfjgqitntkmclb"\n' > "$1/supabase/config.toml"
  (cd "$1" && supabase functions download msg91-otp --project-ref "$QA_REF" --use-api >"$WORK/download.log" 2>&1) || die download_failed
}
schema() {
  python3 - "$ROOT" <<'PY'
import os, sys
sys.path.insert(0,sys.argv[1]+"/scripts/genie-qa")
from verify_qa_target import validate_target
try:
    validate_target(os.environ.get("QA_DATABASE_URL",""), mode="apply")
except ValueError:
    raise SystemExit("QA database target denied")
PY
  test -n "${QA_CA_CERT_PEM:-}" || die ca_missing
  printf '%s\n' "$QA_CA_CERT_PEM" > "$WORK/ca.pem"
  openssl x509 -in "$WORK/ca.pem" -noout >/dev/null 2>&1 || die ca_invalid
  export PGSSLMODE=verify-full PGSSLROOTCERT="$WORK/ca.pem" PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000'
  git -C "$ROOT" ls-tree -r --name-only a4ec8aafc41afa14717c092e583ebb697fe000ef -- supabase/migrations | sed -nE 's@^supabase/migrations/([0-9]{14})_[^/]+\.sql$@\1@p' | sort > "$WORK/expected-ledger"
  [[ "$(wc -l < "$WORK/expected-ledger")" -eq 516 ]] || die ledger_count
  psql "$QA_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 -c 'SELECT version FROM supabase_migrations.schema_migrations ORDER BY version' > "$WORK/live-ledger" 2>/dev/null || die ledger_read
  cmp -s "$WORK/expected-ledger" "$WORK/live-ledger" || die ledger_drift
  local state
  state="$(psql "$QA_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 -c "
    SELECT (SELECT count(*) FROM auth.users)||'|'||
      (SELECT count(*) FROM auth.identities)||'|'||
      (SELECT count(*) FROM auth.sessions)||'|'||
      (SELECT count(*) FROM auth.refresh_tokens)||'|'||
      (SELECT count(*) FROM public.users)||'|'||
      (SELECT count(*) FROM public.users WHERE id='c1000000-0000-4000-8000-000000000001' AND role='system_service' AND is_active)||'|'||
      (SELECT count(*) FROM public.companies)||'|'||
      (SELECT count(*) FROM public.companies WHERE (id,business_name) IN (('a6150000-0000-4000-8000-000000000001'::uuid,'GENIE-QA-COMPANY-A'),('a6150000-0000-4000-8000-000000000002'::uuid,'GENIE-QA-COMPANY-B')) AND status='active' AND NOT is_frozen)||'|'||
      (SELECT count(*) FROM public.b2b_applications)||'|'||
      (SELECT count(*) FROM public.b2b_applications WHERE (id,resolved_company_id) IN (('a6151000-0000-4000-8000-000000000001'::uuid,'a6150000-0000-4000-8000-000000000001'::uuid),('a6151000-0000-4000-8000-000000000002'::uuid,'a6150000-0000-4000-8000-000000000002'::uuid)) AND status='approved' AND user_id IS NULL)||'|'||
      (SELECT count(*) FROM public.profiles)||'|'||
      EXISTS(SELECT 1 FROM pg_extension WHERE extname IN ('pg_cron','pg_net','http','dblink'))
  " 2>/dev/null)" || die schema_read
  [[ "$state" == '1|0|0|0|1|1|2|2|2|2|0|false' ]] || die fixture_or_identity_drift
}
capture() {
  mkdir -- "$WORK"
  assert_main
  schema
  inventory
  baseline
  mkdir "$WORK/evidence"
  cp "$WORK/current-siblings.json" "$WORK/evidence/siblings.json"
  cp "$WORK/current-otp.json" "$WORK/evidence/otp-before.json"
  bash "$ROOT/scripts/genie-qa/stage_msg91_provider_candidate.sh" "$QA_REF" "$WORK/expected"
  # The active rollback baseline is the first diagnostic guard from Core #617.
  git -C "$ROOT" show dfdcc9a3708a69255d25fa9967181f74e8efbedd:scripts/genie-qa/qa-msg91-provider-diagnostic-guard.mjs \
    > "$WORK/expected/supabase/functions/msg91-otp/qa-msg91-provider-guard.mjs" || die baseline_source_unavailable
  closure "$WORK/expected" "$WORK/expected-otp-source.json"
  download "$WORK/rollback"
  closure "$WORK/rollback" "$WORK/rollback-source.json"
  cmp -s "$WORK/expected-otp-source.json" "$WORK/rollback-source.json" || die baseline_source_mismatch
  python3 "$ROOT/scripts/genie-qa/archive_qa_msg91_closure.py" "$WORK/rollback" "$WORK/rollback-source.json" "$WORK/evidence/msg91-otp-rollback.tgz" || die archive_failed
  mkdir "$WORK/rehearsal"
  tar -xzf "$WORK/evidence/msg91-otp-rollback.tgz" -C "$WORK/rehearsal"
  closure "$WORK/rehearsal" "$WORK/rehearsal-source.json"
  cmp -s "$WORK/rollback-source.json" "$WORK/rehearsal-source.json" || die rollback_rehearsal
  cp "$WORK/rollback-source.json" "$WORK/evidence/rollback-source.json"
  bash "$ROOT/scripts/genie-qa/stage_msg91_diagnostic.sh" "$QA_REF" "$WORK/candidate"
  cp "$WORK/candidate/diagnostic-source.json" "$WORK/evidence/candidate-source.json"
  printf '%s\n' "$EXPECTED_SHA" > "$WORK/evidence/release-sha.txt"
  (cd "$WORK/evidence" && sha256sum -- * > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)
  inventory
  cmp -s "$WORK/current-siblings.json" "$WORK/evidence/siblings.json" || die sibling_changed
  cmp -s "$WORK/current-otp.json" "$WORK/evidence/otp-before.json" || die otp_changed
  assert_main
  echo 'GENIE_QA_DIAGNOSTIC_PREFLIGHT_PASS; rollback extracted and source verified; no deployment'
}
capture_failure() {
  local code="$1"
  [[ "$code" -ne 0 ]] || return 0
  trap - EXIT
  set +e
  local evidence="$WORK/failure-evidence"
  mkdir -p "$evidence" || return "$code"
  printf '%s\n' "$failure_phase" > "$evidence/failed-stage.txt"
  printf '%s\n' "$code" > "$evidence/exit-code.txt"
  printf '%s\n' "$EXPECTED_SHA" > "$evidence/release-sha.txt"
  printf '%s\n' "$ROLLBACK_ARTIFACT_ID" > "$evidence/rollback-artifact-id.txt"
  if curl --fail --silent --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$QA_REF/functions" > "$WORK/failure-inventory-raw.json" 2>/dev/null &&
    python3 "$ROOT/scripts/genie-qa/sanitize_gateway_failure_inventory.py" "$WORK/failure-inventory-raw.json" "$evidence/function-inventory.json"; then
    printf 'metadata captured; owner must review before rollback\n' > "$evidence/inventory-status.txt"
  else
    printf 'metadata unavailable or invalid; owner must inspect QA before rollback\n' > "$evidence/inventory-status.txt"
  fi
  rm -f "$WORK/failure-inventory-raw.json"
  return "$code"
}
deploy() {
  [[ "$QA_MODE" == deploy && "${ROLLBACK_ARTIFACT_ID:-}" =~ ^[0-9]+$ ]] || die approval
  assert_main
  (cd "$WORK/evidence" && sha256sum -c SHA256SUMS >/dev/null) || die checksum
  schema
  inventory
  cmp -s "$WORK/current-siblings.json" "$WORK/evidence/siblings.json" || die sibling_changed
  cmp -s "$WORK/current-otp.json" "$WORK/evidence/otp-before.json" || die otp_changed
  closure "$WORK/candidate" "$WORK/candidate-recheck.json"
  cmp -s "$WORK/candidate-recheck.json" "$WORK/evidence/candidate-source.json" || die candidate_changed
  assert_main
  failure_phase=deploy_otp
  trap 'capture_failure "$?"' EXIT
  (cd "$WORK/candidate" && supabase functions deploy msg91-otp --project-ref "$QA_REF" --no-verify-jwt --use-api >"$WORK/deploy.log" 2>&1) || die deploy_failed
  failure_phase=attestation
  inventory
  cmp -s "$WORK/current-siblings.json" "$WORK/evidence/siblings.json" || die sibling_changed
  jq -e --slurpfile before "$WORK/evidence/otp-before.json" '.version>$before[0].version and .ezbr_sha256!=$before[0].ezbr_sha256' "$WORK/current-otp.json" >/dev/null || die otp_not_advanced
  cp "$WORK/current-otp.json" "$WORK/otp-after.json"
  download "$WORK/verified"
  closure "$WORK/verified" "$WORK/verified-source.json"
  cmp -s "$WORK/verified-source.json" "$WORK/evidence/candidate-source.json" || die deployed_source_mismatch
  inventory
  cmp -s "$WORK/current-otp.json" "$WORK/otp-after.json" || die otp_changed
  cmp -s "$WORK/current-siblings.json" "$WORK/evidence/siblings.json" || die sibling_changed
  assert_main
  mkdir "$WORK/post-evidence"
  cp "$WORK/otp-after.json" "$WORK/verified-source.json" "$WORK/current-siblings.json" "$WORK/post-evidence/"
  printf '%s\n' "$EXPECTED_SHA" > "$WORK/post-evidence/release-sha.txt"
  printf '%s\n' "$ROLLBACK_ARTIFACT_ID" > "$WORK/post-evidence/rollback-artifact-id.txt"
  echo 'GENIE_QA_DIAGNOSTIC_DEPLOYED_DISABLED; OTP source attested; no provider request or UAT'
  trap - EXIT
}
case "${1:-}" in
  capture) [[ ! -e "$WORK" && ! -L "$WORK" ]] || die workspace; capture ;;
  deploy) [[ -d "$WORK/evidence" ]] || die missing_preflight; deploy ;;
  *) die invocation ;;
esac
