#!/usr/bin/env bash
set -euo pipefail
umask 077
QA_REF=skhpmltfjgqitntkmclb
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$RUNNER_TEMP/genie-qa-buyer-gateway"
die() { printf 'GENIE_QA_GATEWAY_DENIED: %s\n' "$1" >&2; exit 1; }
[[ "${GITHUB_REPOSITORY:-}" == oasisbaklawa2006/oasis-supabase-core && "${GITHUB_REF:-}" == refs/heads/main && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
   "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ && "${GITHUB_SHA:-}" == "$EXPECTED_SHA" && "${QA_MODE:-}" =~ ^(preflight|deploy)$ &&
   "${QA_CHANGE_REFERENCE:-}" =~ ^Core#495/Buyer#64\;QA-EDGE-APPROVAL=[A-Za-z0-9._/-]{6,128}$ &&
   -n "${SUPABASE_ACCESS_TOKEN:-}" && -n "${GH_TOKEN:-}" ]] || die scope
if [[ "$QA_MODE" == deploy ]]; then
  [[ "${QA_APPROVAL:-}" == AUTHORIZE-GENIE-QA-BUYER-LOGIN-GATEWAY ]] || die authorization
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
  local phase="$1"
  api secrets "$WORK/secrets.json"
  python3 "$ROOT/scripts/genie-qa/verify_qa_real_provider_secret_inventory.py" "$WORK/secrets.json" || die secret_inventory
  api functions "$WORK/functions.json"
  jq -e --arg phase "$phase" '
    type=="array" and
    (map(.slug)|sort)==(if $phase=="before" then ["msg91-otp","msg91-session-bridge"] else ["buyer-login-gateway","msg91-otp","msg91-session-bridge"] end) and
    all(.[]; .status=="ACTIVE" and .verify_jwt==false)
  ' "$WORK/functions.json" >/dev/null || die function_inventory
  jq -e '
    any(.[]; .slug=="msg91-otp" and .ezbr_sha256=="3f4b5a9a8638fd712515bb9c49d056222a4fc3d2017f9142cb9114b2353f3639" and (.version|type)=="number" and .version>=5 and (.version|floor)==.version) and
    any(.[]; .slug=="msg91-session-bridge" and .ezbr_sha256=="47c64fb7996548e59301cff7bfe2886a9e06a3bb41b0ff168676abfd8c0d5ee3" and (.version|type)=="number" and .version>=5 and (.version|floor)==.version)
  ' "$WORK/functions.json" >/dev/null || die existing_bundle_drift
  jq -S '[.[]|select(.slug!="buyer-login-gateway")|{slug,version,status,verify_jwt,ezbr_sha256}]|sort_by(.slug)' "$WORK/functions.json" > "$WORK/current-existing.json"
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
  inventory before
  mkdir "$WORK/evidence"
  cp "$WORK/current-existing.json" "$WORK/evidence/existing-bundles.json"
  printf 'buyer-login-gateway absent; first deployment; rollback is separately approved removal of exact attested gateway only\n' > "$WORK/evidence/rollback-absence.txt"
  bash "$ROOT/scripts/genie-qa/stage_buyer_login_gateway.sh" "$QA_REF" "$WORK/candidate"
  cp "$WORK/candidate/gateway-source.json" "$WORK/evidence/gateway-source.json"
  printf '%s\n' "$EXPECTED_SHA" > "$WORK/evidence/release-sha.txt"
  (cd "$WORK/evidence" && sha256sum -- * > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)
  inventory before
  cmp -s "$WORK/current-existing.json" "$WORK/evidence/existing-bundles.json" || die existing_metadata_changed
  assert_main
  echo 'GENIE_QA_GATEWAY_PREFLIGHT_PASS; absent baseline and candidate captured; no deployment'
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
  inventory before
  cmp -s "$WORK/current-existing.json" "$WORK/evidence/existing-bundles.json" || die existing_metadata_changed
  python3 "$ROOT/scripts/edge-function-source-manifest.py" "$WORK/candidate/supabase/functions" buyer-login-gateway --output "$WORK/recheck.json"
  cmp -s "$WORK/recheck.json" "$WORK/evidence/gateway-source.json" || die candidate_changed
  # From this point onward a failed command may leave a live first deployment.
  # Capture only validated metadata and fixed stage/exit markers, never raw CLI output.
  trap 'capture_failure "$?"' EXIT
  failure_phase=deploy
  (cd "$WORK/candidate" && supabase functions deploy buyer-login-gateway --project-ref "$QA_REF" --no-verify-jwt --use-api >"$WORK/deploy.log" 2>&1) || die deploy_failed
  failure_phase=download_and_attest
  api functions/buyer-login-gateway "$WORK/before.json"
  mkdir -p "$WORK/download/supabase/functions"
  cp "$WORK/candidate/supabase/config.toml" "$WORK/download/supabase/config.toml"
  (cd "$WORK/download" && supabase functions download buyer-login-gateway --project-ref "$QA_REF" --use-api >"$WORK/download.log" 2>&1) || die download_failed
  python3 "$ROOT/scripts/edge-function-source-manifest.py" "$WORK/download/supabase/functions" buyer-login-gateway --output "$WORK/downloaded.json"
  cmp -s "$WORK/downloaded.json" "$WORK/evidence/gateway-source.json" || die source_mismatch
  api functions/buyer-login-gateway "$WORK/after.json"
  for phase in before after; do
    jq -e '.slug=="buyer-login-gateway" and .status=="ACTIVE" and .verify_jwt==false and (.version|type)=="number" and .version>0 and (.version|floor)==.version and (.ezbr_sha256|test("^[0-9a-f]{64}$"))' "$WORK/$phase.json" >/dev/null || die gateway_metadata
    jq -S '{slug,version,status,verify_jwt,ezbr_sha256}' "$WORK/$phase.json" > "$WORK/$phase-pin.json"
  done
  cmp -s "$WORK/before-pin.json" "$WORK/after-pin.json" || die gateway_changed
  failure_phase=final_inventory
  inventory after
  cmp -s "$WORK/current-existing.json" "$WORK/evidence/existing-bundles.json" || die existing_metadata_changed
  jq -S '.[]|select(.slug=="buyer-login-gateway")|{slug,version,status,verify_jwt,ezbr_sha256}' "$WORK/functions.json" > "$WORK/final-pin.json"
  cmp -s "$WORK/after-pin.json" "$WORK/final-pin.json" || die final_gateway_changed
  failure_phase=write_attestation
  mkdir "$WORK/post-evidence"
  cp "$WORK/final-pin.json" "$WORK/downloaded.json" "$WORK/post-evidence/"
  printf '%s\n' "$EXPECTED_SHA" > "$WORK/post-evidence/release-sha.txt"
  printf '%s\n' "$ROLLBACK_ARTIFACT_ID" > "$WORK/post-evidence/rollback-artifact-id.txt"
  echo 'GENIE_QA_GATEWAY_DEPLOYED_DISABLED; source attested; no OTP or UAT'
  trap - EXIT
}
case "${1:-}" in
  capture) [[ ! -e "$WORK" && ! -L "$WORK" ]] || die workspace; capture ;;
  deploy) [[ -d "$WORK/evidence" ]] || die missing_preflight; deploy ;;
  *) die invocation ;;
esac
