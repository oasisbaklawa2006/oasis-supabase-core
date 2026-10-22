#!/usr/bin/env bash
# Integration test: the reviewed certification wrapper runs from a separate
# tools checkout while the caller's working directory is the pinned release
# checkout (the certify-existing layout). Every nested tool it executes must
# come from the reviewed tools checkout, never from the release checkout.
#
# The release checkout's scripts/ is poisoned: any invocation of a stale tool
# is recorded and fails the test. External services are stubbed (supabase,
# docker, `gh attestation verify`); certification decisions are real.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

project_ref="tcxvcatsqqertcnycuop"
function_name="worker"
gh_repo="oasisbaklawa2006/oasis-supabase-core"
release_sha="e9ba0fc9ede29760ef503eb9fb474a01a8a17ca5"
bundle_sha="4fa4639f8c0db5e3d1447e3b4d9e2a1f2ea2e8d382ce1adca1e6637a0bec9d99"
source_run_id="39688382529"
stale_log="$tmp/stale-tools.log"

# --- pinned release checkout (caller cwd), with poisoned stale tools ---
release="$tmp/release"
mkdir -p "$release/scripts"
git -C "$release" init -q
for tool in run-deployed-edge-function-source-certification.sh \
            verify-worker-deployment-source-attestation.sh \
            verify-deployed-edge-function-source-closure.sh \
            download-live-edge-function-bundle-provenance.sh; do
  printf '#!/usr/bin/env bash\necho "STALE_TOOL_INVOKED: %s" >>"%s"\nexit 2\n' \
    "$tool" "$stale_log" >"$release/scripts/$tool"
done
cat >"$release/scripts/edge-function-source-manifest.py" <<EOF
import sys
with open("$stale_log", "a") as log:
    log.write("STALE_TOOL_INVOKED: edge-function-source-manifest.py\n")
sys.exit(2)
EOF

# --- reviewed tools checkout, nested inside the release checkout ---
tools="$release/certification-tools"
mkdir -p "$tools/scripts"
for tool in run-deployed-edge-function-source-certification.sh \
            verify-worker-deployment-source-attestation.sh \
            verify-deployed-edge-function-source-closure.sh \
            download-live-edge-function-bundle-provenance.sh \
            edge-function-source-manifest.py; do
  cp "$repo_root/scripts/$tool" "$tools/scripts/$tool"
done

# --- reviewed source and target manifest (via the reviewed generator) ---
reviewed="$tmp/reviewed"
mkdir -p "$reviewed/$function_name" "$reviewed/whatsapp-content-interpret"
printf 'import { run } from "../whatsapp-content-interpret/sanitize.ts";\nrun();\n' \
  >"$reviewed/$function_name/index.ts"
printf 'import type { SourceKind } from "./types.ts";\nexport function run(): void {}\n' \
  >"$reviewed/whatsapp-content-interpret/sanitize.ts"
printf 'export type SourceKind = "text";\n' \
  >"$reviewed/whatsapp-content-interpret/types.ts"
python3 "$repo_root/scripts/edge-function-source-manifest.py" \
  "$reviewed" "$function_name" --output "$release/target-source-manifest.json"
closure_sha="$(jq -er '.closureSha256' "$release/target-source-manifest.json")"
jq -n --arg sha "$bundle_sha" '{ezbr_sha256: $sha}' >"$release/live-function-after.json"

# --- stubbed external services ---
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
# Docker unbundle path reports unavailable, so only the API download is used.
printf '#!/usr/bin/env bash\nexit 1\n' >"$stub_bin/docker"
# `supabase functions download --use-api` returns the bundled sources; the
# type-only dependency is present only when API_INCLUDES_TYPES=1.
cat >"$stub_bin/supabase" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$1 \$2" == "functions download" && " \$* " == *" --use-api "* ]] || exit 1
out="supabase/functions"
mkdir -p "\$out/$function_name" "\$out/whatsapp-content-interpret"
cp "$reviewed/$function_name/index.ts" "\$out/$function_name/index.ts"
cp "$reviewed/whatsapp-content-interpret/sanitize.ts" "\$out/whatsapp-content-interpret/sanitize.ts"
if [[ "\${API_INCLUDES_TYPES:-0}" == 1 ]]; then
  cp "$reviewed/whatsapp-content-interpret/types.ts" "\$out/whatsapp-content-interpret/types.ts"
fi
EOF
chmod +x "$stub_bin/docker" "$stub_bin/supabase"

# `gh attestation verify` stand-in: emits the verified result in ATTESTATION_JSON.
cat >"$stub_bin/fake-attestation-verify" <<'EOF'
#!/usr/bin/env bash
cat "$ATTESTATION_JSON"
EOF
chmod +x "$stub_bin/fake-attestation-verify"

write_attestation() {
  local run_uri="$1" out="$2"
  jq -n \
    --arg run_uri "$run_uri" \
    --arg release_sha "$release_sha" \
    --arg project_ref "$project_ref" \
    --arg function_name "$function_name" \
    --arg closure_sha "$closure_sha" \
    --arg bundle_sha "$bundle_sha" \
    '[{verificationResult: {
        signature: {certificate: (if $run_uri == "" then {} else {runInvocationURI: $run_uri} end)},
        statement: {predicate: {
          releaseSha: $release_sha, supabaseProjectRef: $project_ref,
          function: $function_name, reviewedSourceClosureSha256: $closure_sha,
          deployedBundleSha256: $bundle_sha}}}}]' >"$out"
}

expected_uri="https://github.com/$gh_repo/actions/runs/$source_run_id/attempts/1"
write_attestation "$expected_uri" "$tmp/right-run.json"
write_attestation "https://github.com/$gh_repo/actions/runs/11111111111/attempts/1" "$tmp/wrong-run.json"
write_attestation "https://github.com/$gh_repo/actions/runs/$source_run_id/attempts/2" "$tmp/wrong-attempt.json"
write_attestation "" "$tmp/no-run.json"

# run_wrapper <attestation.json> <api_includes_types> [run_id] -> prints "<rc> <status>"
run_wrapper() {
  local attestation="$1" include_types="$2" run_id="${3:-}"
  local args=("$project_ref" "$function_name" target-source-manifest.json
              live-function-after.json live-source-manifest.json status.txt
              "$gh_repo" "$release_sha")
  [[ -n "$run_id" ]] && args+=("$run_id")
  rm -f "$release/status.txt" "$release/live-source-manifest.json"
  set +e
  (
    cd "$release"
    PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin" \
    ATTESTATION_VERIFY_CMD="$stub_bin/fake-attestation-verify" \
    ATTESTATION_JSON="$attestation" \
    API_INCLUDES_TYPES="$include_types" \
      bash certification-tools/scripts/run-deployed-edge-function-source-certification.sh "${args[@]}"
  ) >"$tmp/wrapper.log" 2>&1
  local rc=$?
  set -e
  printf '%s %s\n' "$rc" "$(cat "$release/status.txt" 2>/dev/null || echo MISSING)"
}

fail() {
  echo "FAIL: $*" >&2
  echo "--- wrapper output ---" >&2
  cat "$tmp/wrapper.log" >&2 || true
  echo "--- stale tool log ---" >&2
  cat "$stale_log" >&2 2>/dev/null || echo "(none)" >&2
  exit 1
}

assert_case() {
  local label="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
  [[ ! -e "$stale_log" ]] || fail "$label: wrapper executed a stale release-checkout tool"
  echo "ok - $label ($actual)"
}

# 1. Erased type-only file + attestation signed by the pinned deployment run.
assert_case "pinned run attestation" "0 VERIFIED_BY_ATTESTATION" \
  "$(run_wrapper "$tmp/right-run.json" 0 "$source_run_id")"

# 2. Valid predicate, but signed by a different deployment run.
assert_case "wrong signing run rejected" "1 FAILED" \
  "$(run_wrapper "$tmp/wrong-run.json" 0 "$source_run_id")"

# 3. Pinned run, but a re-run attempt rather than the first attempt.
assert_case "wrong signing attempt rejected" "1 FAILED" \
  "$(run_wrapper "$tmp/wrong-attempt.json" 0 "$source_run_id")"

# 4. Verified certificate carries no run identity at all.
assert_case "missing signing run rejected" "1 FAILED" \
  "$(run_wrapper "$tmp/no-run.json" 0 "$source_run_id")"

# 5. Deploy-job path (no pinned run): predicate checks only, still reviewed tools.
assert_case "unpinned eight-argument path" "0 VERIFIED_BY_ATTESTATION" \
  "$(run_wrapper "$tmp/right-run.json" 0)"

# 6. Full closure recovered: the closure verifier's own nested manifest
#    generator must also come from the reviewed tools checkout.
assert_case "full closure via reviewed manifest generator" "0 VERIFIED" \
  "$(run_wrapper "$tmp/right-run.json" 1 "$source_run_id")"

echo "verify-certification-wrapper-tool-resolution passed."
