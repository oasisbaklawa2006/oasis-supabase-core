#!/usr/bin/env bash
# Owner-reviewed, QA-only release. Provider stays disabled throughout.
set -euo pipefail
umask 077
export LC_ALL=C
QA_REF=skhpmltfjgqitntkmclb
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$RUNNER_TEMP/genie-qa-real-provider"
SLUGS=(msg91-otp msg91-session-bridge)
OTP_HASH=0beb542704da4f2623ab5de3a18c429773f1bbab2bbd5cc5ce74c58f34155540
BRIDGE_HASH=e08d1477185fb6ddee691c92d72c4b2ff59889e612e44f983a8dd33bb428cb55
die() { printf 'GENIE_QA_REAL_PROVIDER_DENIED: %s\n' "$1" >&2; exit 1; }
[[ "${GITHUB_REPOSITORY:-}" == oasisbaklawa2006/oasis-supabase-core &&
   "${GITHUB_REF:-}" == refs/heads/main &&
   "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
   "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ &&
   "${GITHUB_SHA:-}" == "$EXPECTED_SHA" &&
   "${QA_MODE:-}" =~ ^(preflight|deploy)$ &&
   "${QA_CHANGE_REFERENCE:-}" =~ ^Core#495/Buyer#64\;QA-EDGE-APPROVAL=[A-Za-z0-9._/-]{6,128}$ &&
   -n "${SUPABASE_ACCESS_TOKEN:-}" && -n "${GH_TOKEN:-}" ]] || die scope
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_SHA" ]] || die checkout
if [[ "$QA_MODE" == deploy ]]; then
  [[ "${QA_APPROVAL:-}" == AUTHORIZE-GENIE-QA-REAL-PROVIDER-BUNDLES ]] || die authorization
else
  [[ -z "${QA_APPROVAL:-}" ]] || die unexpected_authorization
fi
assert_main() {
  [[ "$(gh api repos/oasisbaklawa2006/oasis-supabase-core/git/ref/heads/main --jq .object.sha 2>/dev/null)" == "$EXPECTED_SHA" ]] || die main_moved
}
api() {
  # All requests are GET and project-local. No redirects or error bodies.
  curl --fail --silent --show-error --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$QA_REF/$1" > "$2" 2>/dev/null || die management_read
}
assert_inventory() {
  api functions "$WORK/functions.json"
  jq -e 'type=="array" and length==2 and ([.[].slug]|sort)==["msg91-otp","msg91-session-bridge"] and all(.[]; .status=="ACTIVE")' "$WORK/functions.json" >/dev/null || die function_inventory
  api secrets "$WORK/secret-inventory.json"
  # Only names enter the validator. Do not echo names, digests or values.
  python3 "$ROOT/scripts/genie-qa/verify_qa_real_provider_secret_inventory.py" "$WORK/secret-inventory.json" || die secret_inventory
}
meta() {
  local slug="$1" output="$2"
  api "functions/$slug" "$output"
  jq -e --arg slug "$slug" '.slug==$slug and .status=="ACTIVE" and .verify_jwt==false and (.version|type)=="number" and (.ezbr_sha256|type)=="string" and (.ezbr_sha256|test("^[0-9a-f]{64}$"))' "$output" >/dev/null || die metadata
}
baseline() {
  local slug="$1" output="$2" expected="$OTP_HASH"
  [[ "$slug" != msg91-session-bridge ]] || expected="$BRIDGE_HASH"
  meta "$slug" "$output"
  jq -e --arg hash "$expected" '.version==1 and .ezbr_sha256==$hash' "$output" >/dev/null || die baseline_changed
}
closure() {
  python3 "$ROOT/scripts/edge-function-source-manifest.py" "$1/supabase/functions" "$2" --output "$3" || die source_manifest
}
download() {
  local slug="$1" dir="$2"
  mkdir -- "$dir"
  mkdir -p "$dir/supabase/functions"
  printf 'project_id = "skhpmltfjgqitntkmclb"\n' > "$dir/supabase/config.toml"
  (cd "$dir" && supabase functions download "$slug" --project-ref "$QA_REF" --use-api >"$WORK/download.log" 2>&1) || die source_download
}
assert_schema() {
  # Exact original QA schema, no customer fixtures or egress before release.
  python3 - "$ROOT" <<'PY'
import os,sys
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
  local migration_pin=a4ec8aafc41afa14717c092e583ebb697fe000ef
  git -C "$ROOT" merge-base --is-ancestor "$migration_pin" "$EXPECTED_SHA" || die migration_pin
  git -C "$ROOT" ls-tree -r --name-only "$migration_pin" -- supabase/migrations | sed -nE 's@^supabase/migrations/([0-9]{14})_[^/]+\.sql$@\1@p' | sort > "$WORK/expected-ledger"
  [[ "$(wc -l < "$WORK/expected-ledger")" -eq 516 ]] || die migration_count
  psql "$QA_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 -c 'SELECT version FROM supabase_migrations.schema_migrations ORDER BY version' > "$WORK/live-ledger" 2>/dev/null || die ledger_read
  cmp -s "$WORK/expected-ledger" "$WORK/live-ledger" || die ledger_drift
  local state
  state="$(psql "$QA_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 -c "
    SELECT (SELECT count(*) FROM auth.users)||'|'||
    (SELECT count(*) FROM auth.identities)||'|'||
    (SELECT count(*) FROM auth.sessions)||'|'||
    (SELECT count(*) FROM auth.refresh_tokens)||'|'||
    (SELECT count(*) FROM public.users)||'|'||
    (SELECT count(*) FROM auth.users WHERE id='c1000000-0000-4000-8000-000000000001'::uuid AND email='whatsapp-autonomous-system@system.oasis.internal')||'|'||
    (SELECT count(*) FROM public.users WHERE id='c1000000-0000-4000-8000-000000000001'::uuid AND role='system_service' AND is_active IS TRUE)||'|'||
    EXISTS(SELECT 1 FROM pg_extension WHERE extname IN ('pg_cron','pg_net','http','dblink'))||'|'||
    (to_regclass('cron.job') IS NOT NULL)
  " 2>/dev/null)" || die schema_read
  [[ "$state" == '1|0|0|0|1|1|1|false|false' ]] || die schema_or_identity_drift
}
capture() {
  mkdir -- "$WORK"
  assert_main
  assert_schema
  assert_inventory
  mkdir "$WORK/evidence"
  bash "$ROOT/scripts/genie-qa/stage_msg91_provider_candidate.sh" "$QA_REF" "$WORK/candidate"
  # Independent expected inert source closure from canonical source at this SHA.
  mkdir -p "$WORK/inert/supabase/functions"
  cp -a "$ROOT/supabase/functions/msg91-otp" "$ROOT/supabase/functions/msg91-session-bridge" "$ROOT/supabase/functions/_shared" "$WORK/inert/supabase/functions/"
  cp "$ROOT/scripts/genie-qa/inert_msg91_provider_verify.mjs" "$WORK/inert/supabase/functions/msg91-otp/provider-verify.mjs"
  for slug in "${SLUGS[@]}"; do
    baseline "$slug" "$WORK/$slug-before.json"
    download "$slug" "$WORK/rollback-$slug"
    baseline "$slug" "$WORK/$slug-after.json"
    closure "$WORK/inert" "$slug" "$WORK/$slug-inert.json"
    closure "$WORK/rollback-$slug" "$slug" "$WORK/$slug-downloaded.json"
    cmp -s "$WORK/$slug-inert.json" "$WORK/$slug-downloaded.json" || die inert_closure_mismatch
    cmp -s "$ROOT/scripts/genie-qa/inert_msg91_provider_verify.mjs" "$WORK/rollback-$slug/supabase/functions/msg91-otp/provider-verify.mjs" || die inert_overlay_mismatch
    # Archive ONLY paths in the attested local import closure plus generated config.
    python3 "$ROOT/scripts/genie-qa/archive_qa_msg91_closure.py" "$WORK/rollback-$slug" "$WORK/$slug-downloaded.json" "$WORK/evidence/$slug-v1.tgz" || die archive
    mkdir "$WORK/rehearsal-$slug"
    tar -xzf "$WORK/evidence/$slug-v1.tgz" -C "$WORK/rehearsal-$slug" || die archive_extract
    closure "$WORK/rehearsal-$slug" "$slug" "$WORK/$slug-restorable.json"
    cmp -s "$WORK/$slug-downloaded.json" "$WORK/$slug-restorable.json" || die archive_source_mismatch
    cp "$WORK/$slug-inert.json" "$WORK/evidence/$slug-inert-manifest.json"
    cp "$WORK/candidate/$slug-source.json" "$WORK/evidence/$slug-candidate-manifest.json"
    jq '{slug,version,status,verify_jwt,ezbr_sha256}' "$WORK/$slug-before.json" > "$WORK/evidence/$slug-baseline.json"
  done
  (cd "$WORK/evidence" && sha256sum -- * > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null) || die archive_checksum
  assert_inventory
  for slug in "${SLUGS[@]}"; do baseline "$slug" "$WORK/$slug-final-preflight.json"; done
  assert_main
  echo 'GENIE_QA_REAL_PROVIDER_PREFLIGHT_PASS; rollback archive extraction and closure parity passed; no deployment'
}
attest() {
  local slug="$1" dir="$2" pin="$3"
  meta "$slug" "$WORK/$slug-post-before.json"
  jq -e '.version>1' "$WORK/$slug-post-before.json" >/dev/null || die version_not_advanced
  download "$slug" "$dir"
  closure "$dir" "$slug" "$WORK/$slug-verified.json"
  cmp -s "$WORK/candidate/$slug-source.json" "$WORK/$slug-verified.json" || die deployed_closure_mismatch
  meta "$slug" "$WORK/$slug-post-after.json"
  python3 "$ROOT/scripts/genie-qa/verify_msg91_bundle_provenance.py" --mode capture --slug "$slug" --before "$WORK/$slug-post-before.json" --after "$WORK/$slug-post-after.json" --pin "$pin" || die deployed_bundle_changed
}
deploy() {
  [[ "$QA_MODE" == deploy && -n "${ROLLBACK_ARTIFACT_ID:-}" && "$ROLLBACK_ARTIFACT_ID" =~ ^[0-9]+$ ]] || die deployment_gate
  assert_main
  (cd "$WORK/evidence" && sha256sum -c SHA256SUMS >/dev/null) || die rollback_checksum
  for slug in "${SLUGS[@]}"; do
    closure "$WORK/candidate" "$slug" "$WORK/$slug-candidate-recheck.json"
    cmp -s "$WORK/evidence/$slug-candidate-manifest.json" "$WORK/$slug-candidate-recheck.json" || die candidate_changed
  done
  assert_schema
  assert_inventory
  for slug in "${SLUGS[@]}"; do baseline "$slug" "$WORK/$slug-immediate.json"; done
  # No activation secret exists, so both new guards deny provider traffic.
  (cd "$WORK/candidate" && supabase functions deploy msg91-otp --project-ref "$QA_REF" --no-verify-jwt --use-api >"$WORK/deploy.log" 2>&1) || die otp_deploy_stop
  attest msg91-otp "$WORK/otp-verified-first" "$WORK/msg91-otp-pin"
  assert_main
  assert_inventory
  baseline msg91-session-bridge "$WORK/bridge-immediate.json"
  (cd "$WORK/candidate" && supabase functions deploy msg91-session-bridge --project-ref "$QA_REF" --no-verify-jwt --use-api >"$WORK/deploy.log" 2>&1) || die partial_deploy_stop_owner_rollback
  attest msg91-session-bridge "$WORK/bridge-verified" "$WORK/msg91-session-bridge-pin"
  attest msg91-otp "$WORK/otp-verified-final" "$WORK/msg91-otp-pin"
  assert_inventory
  mkdir "$WORK/post-evidence"
  for slug in "${SLUGS[@]}"; do
    meta "$slug" "$WORK/$slug-final.json"
    python3 "$ROOT/scripts/genie-qa/verify_msg91_bundle_provenance.py" --mode final --slug "$slug" --metadata "$WORK/$slug-final.json" --pin "$WORK/$slug-pin" || die final_bundle
    jq '{slug,version,status,verify_jwt,ezbr_sha256}' "$WORK/$slug-final.json" > "$WORK/post-evidence/$slug-metadata.json"
    cp "$WORK/$slug-verified.json" "$WORK/post-evidence/$slug-source.json"
  done
  printf '%s\n' "$EXPECTED_SHA" > "$WORK/post-evidence/release-sha.txt"
  printf '%s\n' "$ROLLBACK_ARTIFACT_ID" > "$WORK/post-evidence/rollback-artifact-id.txt"
  echo 'GENIE_QA_REAL_PROVIDER_BUNDLES_DEPLOYED_DISABLED; no provider request or UAT'
}
case "${1:-}" in
  capture) [[ ! -e "$WORK" && ! -L "$WORK" ]] || die workspace; capture ;;
  deploy) [[ -d "$WORK/evidence" ]] || die missing_preflight; deploy ;;
  *) die invocation ;;
esac
