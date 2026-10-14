#!/usr/bin/env bash
# Regression coverage for preview dotenvx key custody hardening.
#
# Proves that a wrong key, an unavailable key, an unattested ciphertext change,
# Management API readback and pull-request key writes can never pass silently.
# Uses only synthetic keys generated in-process; no real secret material and no
# network access to Supabase are involved.
set -euo pipefail

# The production Supabase project ref (the only project the key writer may target).
prod_ref="tcxvcatsqqertcnycuop"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

cases=0
fail() {
  echo "PREVIEW DOTENV AUTHORITY HARDENING REGRESSION FAILED: $*" >&2
  exit 1
}
pass_case() { cases=$((cases + 1)); }

for required in \
  scripts/verify-preview-dotenv-crypto-authority.sh \
  scripts/verify-preview-dotenv-attestation.py \
  scripts/verify-preview-env-decryptable.sh \
  scripts/load-preview-dotenvx-keys.sh \
  scripts/upload-production-dotenvx-key.py \
  scripts/check-preview-edge-runtime-secrets-config.sh \
  scripts/detect-pr-edge-governance-paths.sh; do
  [[ -f "$required" ]] || fail "$required is missing"
done

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

mock_bin="$tmp/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/npx" <<'MOCK_NPX'
#!/usr/bin/env bash
# Stand-in for `npx @dotenvx/dotenvx get ...`; result is chosen by the test.
if [[ "$*" == *" get "* ]]; then
  [[ "${MOCK_DOTENVX_RESULT:-ok}" == ok ]] && exit 0
  exit 1
fi
echo "unexpected npx invocation: $*" >&2
exit 1
MOCK_NPX
cat > "$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_NETWORK_LOG:?}"
exit 1
MOCK_CURL
cat > "$mock_bin/supabase" <<'MOCK_SUPABASE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_NETWORK_LOG:?}"
exit 1
MOCK_SUPABASE
chmod +x "$mock_bin/npx" "$mock_bin/curl" "$mock_bin/supabase"
network_log="$tmp/network.log"
: > "$network_log"

# --- synthetic key material (never printed) --------------------------------
gen_pair() {
  node -e '
const c = require("node:crypto");
const e = c.createECDH("secp256k1");
e.generateKeys();
process.stdout.write(e.getPrivateKey("hex").padStart(64, "0") + " " + e.getPublicKey("hex", "compressed") + "\n");
'
}
read -r key_a pub_a < <(gen_pair)
read -r key_b pub_b < <(gen_pair)
[[ "$pub_a" != "$pub_b" ]] || fail 'synthetic key pairs collided'

make_sandbox() {
  local dir="$1" pub="$2"
  mkdir -p "$dir/scripts" "$dir/supabase"
  cp scripts/verify-preview-dotenv-crypto-authority.sh scripts/verify-preview-dotenv-attestation.py \
     scripts/verify-preview-env-decryptable.sh "$dir/scripts/"
  cat > "$dir/supabase/.env.preview" <<PREVIEW
DOTENV_PUBLIC_KEY_PREVIEW="$pub"
GEMINI_API_KEY="encrypted:AAAAsynthetic"
WA_STAGE1B_CERT_SECRET="encrypted:BBBBsynthetic"
PREVIEW
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@test.local -c user.name=t commit -qm base
}

# verify_in <dir> [VAR=value ...] -> combined output on stdout, status preserved
verify_in() {
  local dir="$1"; shift
  (cd "$dir" && env -i PATH="$mock_bin:$PATH" HOME="$tmp" GIT_CONFIG_GLOBAL=/dev/null \
      MOCK_NETWORK_LOG="$network_log" "$@" bash scripts/verify-preview-dotenv-crypto-authority.sh) 2>&1
}

expect_fail() { # name expected-code dir [env...]
  local name="$1" code="$2" dir="$3"; shift 3
  local output status=0
  output="$(verify_in "$dir" "$@")" || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: unexpectedly passed"
  grep -Fq "$code" <<<"$output" || fail "$name: expected $code, got: $(head -c 300 <<<"$output")"
  ! grep -Fq 'authority_mode=' <<<"$output" || fail "$name: reported an authority mode despite failing"
  pass_case
}
expect_pass() { # name expected-mode dir [env...]
  local name="$1" mode="$2" dir="$3"; shift 3
  local output status=0
  output="$(verify_in "$dir" "$@")" || status=$?
  [[ "$status" -eq 0 ]] || fail "$name: unexpectedly failed: $(head -c 300 <<<"$output")"
  grep -Fxq "authority_mode=$mode" <<<"$output" || fail "$name: expected authority_mode=$mode"
  pass_case
}

# --- 1. independently held key: strict, no fall-through --------------------
s1="$tmp/s1"; make_sandbox "$s1" "$pub_a"
expect_pass 'matching key + decrypt' independent_key "$s1" PREVIEW_DOTENV_PRIVATE_KEY="$key_a" MOCK_DOTENVX_RESULT=ok
[[ ! -e "$s1/supabase/.env.keys" ]] || fail 'verifier left a key file behind'
expect_fail 'wrong key (valid format) with decrypt lying OK' PUBLIC_KEY_MISMATCH "$s1" PREVIEW_DOTENV_PRIVATE_KEY="$key_b" MOCK_DOTENVX_RESULT=ok
expect_fail 'matching key but decrypt fails' DECRYPT_FAILED "$s1" PREVIEW_DOTENV_PRIVATE_KEY="$key_a" MOCK_DOTENVX_RESULT=fail
[[ ! -e "$s1/supabase/.env.keys" ]] || fail 'verifier left a key file after a failed decrypt'
expect_fail 'malformed key' KEY_FORMAT_INVALID "$s1" PREVIEW_DOTENV_PRIVATE_KEY='not-a-hex-key'
expect_fail 'truncated key' KEY_FORMAT_INVALID "$s1" PREVIEW_DOTENV_PRIVATE_KEY="${key_a:0:62}"

# --- 2. custody unavailable: fail closed, never read back from Supabase ----
s2="$tmp/s2"; make_sandbox "$s2" "$pub_a"
expect_fail 'no key and no attestation' KEY_CUSTODY_UNAVAILABLE "$s2"
expect_fail 'no key with a Supabase token present (no readback)' KEY_CUSTODY_UNAVAILABLE "$s2" \
  SUPABASE_ACCESS_TOKEN=present-token PRODUCTION_PROJECT_REF="$prod_ref" HTTPS_PROXY=http://127.0.0.1:9
[[ ! -s "$network_log" ]] || fail 'verifier invoked a network or Supabase CLI client'

s_missing="$tmp/s-missing"; make_sandbox "$s_missing" "$pub_a"; rm -f "$s_missing/supabase/.env.preview"
expect_fail 'ciphertext file missing' ENV_PREVIEW_MISSING "$s_missing" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"
s_plain="$tmp/s-plain"; make_sandbox "$s_plain" "$pub_a"
sed -i 's/^GEMINI_API_KEY=.*/GEMINI_API_KEY="plaintext-value"/' "$s_plain/supabase/.env.preview"
expect_fail 'plaintext entry' GEMINI_API_KEY_NOT_ENCRYPTED "$s_plain" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"
s_nohdr="$tmp/s-nohdr"; make_sandbox "$s_nohdr" "$pub_a"
sed -i '/^DOTENV_PUBLIC_KEY_PREVIEW=/d' "$s_nohdr/supabase/.env.preview"
expect_fail 'public key header missing' PUBLIC_KEY_HEADER_MISSING_OR_INVALID "$s_nohdr" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"

# --- 3. narrow historical attestation --------------------------------------
cat > "$tmp/mock_api.py" <<'MOCK_API'
import http.server, json, sys

routes_path = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def _log(self, kind):
        with open(routes_path + ".log", "a", encoding="utf-8") as handle:
            handle.write(f"{kind} {self.path}\n")

    def do_GET(self):
        self._log("GET")
        with open(routes_path, encoding="utf-8") as handle:
            routes = json.load(handle)
        if self.path in routes:
            body, code = json.dumps(routes[self.path]).encode(), 200
        else:
            body, code = b"{}", 404
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _reject(self):
        self._log("WRITE")
        self.send_response(405)
        self.end_headers()

    do_POST = do_PUT = do_PATCH = do_DELETE = _reject

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
MOCK_API
routes="$tmp/routes.json"
printf '{}' > "$routes"
: > "$routes.log"
python3 "$tmp/mock_api.py" "$routes" > "$tmp/port" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
port="$(cat "$tmp/port")"
[[ "$port" =~ ^[0-9]+$ ]] || fail 'mock GitHub API did not start'
api="http://127.0.0.1:$port"
repo_slug='oasisbaklawa2006/oasis-supabase-core'
commit_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
run_id=4242

s3="$tmp/s3"; make_sandbox "$s3" "$pub_a"
blob="$(git -C "$s3" hash-object supabase/.env.preview)"
other_blob='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

write_attestation() { # blob commit run_id-json
  cat > "$s3/supabase/.env.preview.attestations.json" <<ATT
{"version":1,"attestations":[{"blob":"$1","commit":"$2","check_run_id":$3}]}
ATT
}
good_config='[edge_runtime.secrets]\nGEMINI_API_KEY = "env(GEMINI_API_KEY)"\nWA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"\n'
write_routes() { # check_run_json contents_sha [config_text]
  python3 - "$routes" "$repo_slug" "$run_id" "$commit_sha" "$1" "$2" "${3-$good_config}" <<'PY'
import base64, json, sys
path, repo, run_id, commit, run_json, contents_sha, config_text = sys.argv[1:8]
config_text = config_text.encode().decode("unicode_escape")
routes = {
    f"/repos/{repo}/check-runs/{run_id}": json.loads(run_json),
    f"/repos/{repo}/contents/supabase/.env.preview?ref={commit}": {"sha": contents_sha},
    f"/repos/{repo}/contents/supabase/config.toml?ref={commit}": {
        "encoding": "base64",
        "content": base64.b64encode(config_text.encode()).decode(),
    },
}
open(path, "w").write(json.dumps(routes))
PY
}
good_run() { printf '{"name":"Supabase Preview","status":"completed","conclusion":"success","head_sha":"%s","app":{"id":330661,"slug":"supabase"}}' "$commit_sha"; }
att_env=(GITHUB_API_URL="$api" GITHUB_REPOSITORY="$repo_slug" GH_TOKEN=test-token)

write_attestation "$blob" "$commit_sha" "$run_id"
write_routes "$(good_run)" "$blob"
: > "$routes.log"
expect_pass 'exact attested blob with successful Supabase check-run' attested_blob "$s3" "${att_env[@]}"
! grep -q '^WRITE' "$routes.log" || fail 'attestation verification issued a non-GET request'
! grep -v -E '^GET /repos/oasisbaklawa2006/oasis-supabase-core/(check-runs/4242|contents/supabase/(\.env\.preview|config\.toml)\?ref=a{40})$' "$routes.log" | grep -q . \
  || fail 'attestation verification contacted unexpected endpoints'

# a valid attestation must never rescue a wrong or failing independent key
expect_fail 'wrong key cannot fall through to a valid attestation' PUBLIC_KEY_MISMATCH "$s3" "${att_env[@]}" \
  PREVIEW_DOTENV_PRIVATE_KEY="$key_b" MOCK_DOTENVX_RESULT=ok
expect_fail 'failing decrypt cannot fall through to a valid attestation' DECRYPT_FAILED "$s3" "${att_env[@]}" \
  PREVIEW_DOTENV_PRIVATE_KEY="$key_a" MOCK_DOTENVX_RESULT=fail

# any change to the ciphertext invalidates the attestation (no arbitrary changes)
printf '# changed\n' >> "$s3/supabase/.env.preview"
expect_fail 'changed ciphertext is not covered by the attestation' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
git -C "$s3" checkout -q -- supabase/.env.preview

run_variant() { # name run_json contents_sha
  write_routes "$2" "$3"
  expect_fail "$1" KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
}
run_variant 'check-run conclusion failure' "$(good_run | sed 's/"success"/"failure"/')" "$blob"
run_variant 'check-run still in progress' "$(good_run | sed 's/"completed"/"in_progress"/')" "$blob"
run_variant 'check-run published by another app slug' "$(good_run | sed 's/"slug":"supabase"/"slug":"github-actions"/')" "$blob"
run_variant 'check-run published by another app id' "$(good_run | sed 's/330661/15368/')" "$blob"
run_variant 'check-run with another name' "$(good_run | sed 's/Supabase Preview/Other Check/')" "$blob"
run_variant 'check-run for another commit' "$(good_run | sed "s/$commit_sha/cccccccccccccccccccccccccccccccccccccccc/")" "$blob"
run_variant 'attested commit carries a different blob' "$(good_run)" "$other_blob"
write_routes "$(good_run)" "$blob" '[edge_runtime.secrets]\nGEMINI_API_KEY = "env(GEMINI_API_KEY)"\n'
expect_fail 'attested commit config omits one env() secret declaration' ATTESTED_CONFIG_SECRETS_NOT_DECLARED "$s3" "${att_env[@]}"
write_routes "$(good_run)" "$blob" '# secrets removed\n[api]\nenabled = true\n'
expect_fail 'attested commit config declares no Edge Runtime secrets' ATTESTED_CONFIG_SECRETS_NOT_DECLARED "$s3" "${att_env[@]}"
write_routes "$(good_run)" "$blob" 'GEMINI_API_KEY = "env(GEMINI_API_KEY)"\nWA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"\n'
expect_fail 'attested commit config lacks the edge_runtime.secrets section' ATTESTED_CONFIG_SECRETS_NOT_DECLARED "$s3" "${att_env[@]}"
write_routes "$(good_run)" "$blob"

write_attestation "$other_blob" "$commit_sha" "$run_id"
expect_fail 'attestation for another blob' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
write_attestation "$blob" "$commit_sha" '"4242"'
expect_fail 'check_run_id as string' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
write_attestation "$blob" "$commit_sha" '4242, "note": "x"'
expect_fail 'extra attestation field' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
printf '{not json' > "$s3/supabase/.env.preview.attestations.json"
expect_fail 'malformed attestation file' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"
python3 - "$s3" "$blob" "$commit_sha" <<'PY'
import json, sys
root, blob, commit = sys.argv[1:4]
entries = [{"blob": blob, "commit": commit, "check_run_id": 4242 + i} for i in range(9)]
open(f"{root}/supabase/.env.preview.attestations.json", "w").write(json.dumps({"version": 1, "attestations": entries}))
PY
expect_fail 'oversized attestation list' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"

write_attestation "$blob" "$commit_sha" "$run_id"
expect_fail 'untrusted API base' KEY_CUSTODY_UNAVAILABLE "$s3" GITHUB_API_URL=http://attacker.example GITHUB_REPOSITORY="$repo_slug" GH_TOKEN=test-token
expect_fail 'repository not pinned' KEY_CUSTODY_UNAVAILABLE "$s3" GITHUB_API_URL="$api" GITHUB_REPOSITORY=someone/else GH_TOKEN=test-token
expect_fail 'missing GitHub token' KEY_CUSTODY_UNAVAILABLE "$s3" GITHUB_API_URL="$api" GITHUB_REPOSITORY="$repo_slug"
printf '{}' > "$routes"
expect_fail 'GitHub API returns nothing for the check-run' KEY_CUSTODY_UNAVAILABLE "$s3" "${att_env[@]}"

# --- 4. the shared key can only be written by the protected rotation path --
writer_status=0
writer_out="$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" GITHUB_EVENT_NAME=pull_request PREVIEW_KEY_ROTATION_AUTHORIZED=true \
  PRODUCTION_PROJECT_REF="$prod_ref" SUPABASE_ACCESS_TOKEN=t PREVIEW_DOTENV_PRIVATE_KEY="$key_a" \
  python3 "$repo_root/scripts/upload-production-dotenvx-key.py" 2>&1)" || writer_status=$?
[[ "$writer_status" -ne 0 ]] && grep -Fq PREVIEW_KEY_WRITE_FORBIDDEN <<<"$writer_out" || fail 'key writer ran in a pull_request context'
pass_case
writer_status=0
writer_out="$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" GITHUB_EVENT_NAME=pull_request_target PREVIEW_KEY_ROTATION_AUTHORIZED=true \
  PRODUCTION_PROJECT_REF="$prod_ref" SUPABASE_ACCESS_TOKEN=t PREVIEW_DOTENV_PRIVATE_KEY="$key_a" \
  python3 "$repo_root/scripts/upload-production-dotenvx-key.py" 2>&1)" || writer_status=$?
[[ "$writer_status" -ne 0 ]] && grep -Fq PREVIEW_KEY_WRITE_FORBIDDEN <<<"$writer_out" || fail 'key writer ran in a pull_request_target context'
pass_case
writer_status=0
writer_out="$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" GITHUB_EVENT_NAME=push \
  PRODUCTION_PROJECT_REF="$prod_ref" SUPABASE_ACCESS_TOKEN=t PREVIEW_DOTENV_PRIVATE_KEY="$key_a" \
  python3 "$repo_root/scripts/upload-production-dotenvx-key.py" 2>&1)" || writer_status=$?
[[ "$writer_status" -ne 0 ]] && grep -Fq PREVIEW_KEY_WRITE_FORBIDDEN <<<"$writer_out" || fail 'key writer ran without explicit rotation authorization'
pass_case
writer_status=0
writer_out="$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" GITHUB_EVENT_NAME=workflow_dispatch PREVIEW_KEY_ROTATION_AUTHORIZED=true \
  PRODUCTION_PROJECT_REF=abcdefghijklmnopqrst SUPABASE_ACCESS_TOKEN=t PREVIEW_DOTENV_PRIVATE_KEY="$key_a" \
  python3 "$repo_root/scripts/upload-production-dotenvx-key.py" 2>&1)" || writer_status=$?
[[ "$writer_status" -ne 0 ]] && grep -Fq PREVIEW_KEY_WRITE_FORBIDDEN <<<"$writer_out" || fail 'key writer accepted a non-production target'
pass_case

# --- 5. no Management API readback anywhere ---------------------------------
: > "$network_log"
load_out="$(cd "$tmp" && mkdir -p loadbox/supabase && cd loadbox && git init -q . 2>/dev/null; \
  env -i PATH="$mock_bin:$PATH" HOME="$tmp" MOCK_NETWORK_LOG="$network_log" SUPABASE_ACCESS_TOKEN=present-token \
  PRODUCTION_PROJECT_REF="$prod_ref" bash "$repo_root/scripts/load-preview-dotenvx-keys.sh" 2>&1)"
[[ "$load_out" == 'no_production_dotenvx_private_key' ]] || fail "key loader returned an unexpected state"
[[ ! -s "$network_log" ]] || fail 'key loader contacted Supabase or the network'
pass_case
[[ ! -e scripts/fetch-production-dotenv-private-key.py ]] || fail 'readback script exists'
pass_case

# --- 6. workflow/static mutations must be rejected by the config gate -------
mutated="$tmp/mutated"
fresh_copy() {
  rm -rf "$mutated"; mkdir -p "$mutated"
  tar --exclude=.git -cf - . | tar -xf - -C "$mutated"
  git -C "$mutated" init -q
}
expect_gate_rejects() { # name expected-substring
  local output status=0
  output="$(cd "$mutated" && bash scripts/check-preview-edge-runtime-secrets-config.sh 2>&1)" || status=$?
  [[ "$status" -ne 0 ]] || fail "config gate accepted mutation: $1"
  grep -Fq "$2" <<<"$output" || fail "config gate rejected '$1' for the wrong reason: $(head -c 300 <<<"$output")"
  pass_case
}
fresh_copy
(cd "$mutated" && bash scripts/check-preview-edge-runtime-secrets-config.sh >/dev/null 2>&1) || fail 'config gate rejects the unmutated tree'
pass_case

gov='.github/workflows/edge-function-governance.yml'
sync='.github/workflows/sync-preview-cert-edge-secrets.yml'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('          authority_line="$(bash scripts/verify-preview-dotenv-crypto-authority.sh)"\n',
              '          git push origin HEAD\n          authority_line="$(bash scripts/verify-preview-dotenv-crypto-authority.sh)"\n', 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'provision job pushes to Git' 'read-only'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('          GH_TOKEN: ${{ github.token }}\n          GITHUB_REPOSITORY: ${{ github.repository }}\n          PRODUCTION_PROJECT_REF',
              '          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}\n          GH_TOKEN: ${{ github.token }}\n          GITHUB_REPOSITORY: ${{ github.repository }}\n          PRODUCTION_PROJECT_REF', 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'provision job holds a Supabase token' 'read-only'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('          authority_line="$(bash scripts/verify-preview-dotenv-crypto-authority.sh)"\n',
              '          bash scripts/upload-preview-dotenvx-keys.sh\n          authority_line="$(bash scripts/verify-preview-dotenv-crypto-authority.sh)"\n', 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'provision job calls the key uploader' 'read-only'

fresh_copy; sed -i 's/^  contents: read$/  contents: write/' "$mutated/$gov"
expect_gate_rejects 'governance workflow regains contents: write' 'contents'

fresh_copy; sed -i 's/NEW_PREVIEW_DOTENVX_KEY_REQUIRES_PERSISTED_CIPHERTEXT/SOMETHING_ELSE/' "$mutated/$sync"
expect_gate_rejects 'sync workflow may publish a newly generated key' 'newly generated key'

fresh_copy; sed -i 's/secrets.SUPABASE_PREVIEW_READONLY_TOKEN/secrets.SUPABASE_ACCESS_TOKEN/' "$mutated/$gov"
expect_gate_rejects 'pull-request workflow references the write-capable token' 'write-capable SUPABASE_ACCESS_TOKEN'

fresh_copy; sed -i "/github.ref == 'refs\/heads\/main'/d" "$mutated/$sync"
expect_gate_rejects 'sync workflow may run from a non-main branch' 'main branch'

fresh_copy; python3 - "$mutated/$sync" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  workflow_dispatch:\n", "  pull_request:\n    types: [opened]\n  workflow_dispatch:\n", 1)
open(p, 'w').write(s)
PY2
expect_gate_rejects 'sync workflow regains a pull_request trigger with the write token' 'must not reference the write-capable'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("(needs.path-scope.outputs.edge_runtime != 'true' || needs.provision-preview-dotenv.result == 'success')",
              "(needs.provision-preview-dotenv.result == 'success' || needs.provision-preview-dotenv.result == 'skipped')", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness may run without verified authority' 'readiness must run only after successful'

fresh_copy; printf '#!/usr/bin/env python3\n' > "$mutated/scripts/fetch-production-dotenv-private-key.py"
expect_gate_rejects 'readback script reintroduced' 'readback script must not exist'

fresh_copy; printf 'curl -s https://api.supabase.com/v1/projects/x/secrets\n' >> "$mutated/scripts/load-preview-dotenvx-keys.sh"
expect_gate_rejects 'key loader contacts Supabase' 'local-only'

fresh_copy; cat > "$mutated/.github/workflows/rogue.yml" <<'ROGUE'
name: rogue
on: pull_request
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/upload-preview-dotenvx-keys.sh
ROGUE
expect_gate_rejects 'another workflow invokes the key uploader' 'only the protected sync workflow'

fresh_copy; sed -i "/^    environment: supabase-preview-key-authority$/d" "$mutated/$sync"
expect_gate_rejects 'sync job loses its protected environment' 'protected supabase-preview-key-authority environment'

fresh_copy; sed -i "s/&& inputs.rotation_authorization == 'AUTHORIZE-PREVIEW-DOTENVX-KEY-ROTATION'//" "$mutated/$sync"
expect_gate_rejects 'sync job loses explicit authorization phrase' 'authorization phrase'

fresh_copy; sed -i "s/github.event_name == 'workflow_dispatch'/github.event_name != 'workflow_dispatch'/" "$mutated/$sync"
expect_gate_rejects 'sync job runs outside workflow_dispatch' 'workflow_dispatch'

fresh_copy; sed -i 's/PREVIEW_KEY_ROTATION_AUTHORIZED/PREVIEW_KEY_ROTATION_X/g' "$mutated/scripts/upload-production-dotenvx-key.py"
expect_gate_rejects 'key writer loses its authorization guard' 'rotation authorization'

# --- 7. path scope: hardening is static-only; ciphertext/attestation need hosted readiness
scope="$tmp/scope"
mkdir -p "$scope/scripts" "$scope/supabase"
cp scripts/detect-pr-edge-governance-paths.sh "$scope/scripts/"
printf '[functions.preview-fn]\nverify_jwt = true\n' > "$scope/supabase/config.toml"
printf 'base\n' > "$scope/README.md"
git -C "$scope" init -q
git -C "$scope" config user.email scope@test.local; git -C "$scope" config user.name scope
git -C "$scope" branch -M main
git -C "$scope" add -A; git -C "$scope" commit -qm base
scope_branch() { # name path
  git -C "$scope" checkout -q main; git -C "$scope" checkout -qb "$1"
  mkdir -p "$scope/$(dirname "$2")"; printf 'x\n' > "$scope/$2"
  git -C "$scope" add -A; git -C "$scope" commit -qm "$1"
}
scope_branch hardening-only scripts/verify-preview-dotenv-crypto-authority.sh
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main static)" == true ]] || fail 'hardening change must stay under static Edge governance'
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == false ]] || fail 'verifier-only change must not be misreported as runtime-certified'
scope_branch ciphertext-change supabase/.env.preview
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == true ]] || fail 'ciphertext change must require hosted Edge Runtime readiness'
scope_branch attestation-change supabase/.env.preview.attestations.json
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == true ]] || fail 'attestation change must require hosted Edge Runtime readiness'
pass_case

echo "verify-preview-dotenv-authority-hardening.sh: all ${cases} cases passed"
