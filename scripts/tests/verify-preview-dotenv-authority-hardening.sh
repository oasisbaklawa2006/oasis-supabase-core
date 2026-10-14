#!/usr/bin/env bash
# Regression coverage for preview credential isolation and key custody.
#
# Proves that:
#   * pull-request / branch-controlled workflows can never receive a privileged
#     Supabase credential, a dotenvx private key or a production secret
#     (static gate + mutation tests over every workflow);
#   * the PR readiness path is unprivileged and fails closed: the preview ref
#     and the hosted decryption proof come only from the trusted Supabase
#     GitHub App check-run, never from the Management API, and a missing,
#     skipped, failed or untrusted preview is never reported as success;
#   * the independent-key verifier runs only in the protected workflow and a
#     wrong or absent key can never pass;
#   * Management API readback and pull-request key writes are impossible.
# Uses only synthetic keys generated in-process, a local mock GitHub API and no
# network access to Supabase.
set -euo pipefail

# The production Supabase project ref (the only project the key writer may target).
prod_ref="tcxvcatsqqertcnycuop"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

cases=0
fail() {
  echo "PREVIEW CREDENTIAL ISOLATION REGRESSION FAILED: $*" >&2
  exit 1
}
pass_case() { cases=$((cases + 1)); }

for required in \
  scripts/verify-preview-dotenv-crypto-authority.sh \
  scripts/check-preview-hosted-proof-preconditions.sh \
  scripts/verify-preview-env-decryptable.sh \
  scripts/load-preview-dotenvx-keys.sh \
  scripts/upload-production-dotenvx-key.py \
  scripts/resolve-current-pr-preview-ref.sh \
  scripts/wait-for-current-pr-preview-ref.sh \
  scripts/resolve-current-pr-preview-ref-from-branches.py \
  scripts/check-preview-edge-runtime-secrets-readiness.sh \
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

real_python="$(command -v python3)"
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
if [[ -n "${MOCK_CURL_BODY:-}" ]]; then printf '%s' "$MOCK_CURL_BODY"; exit 0; fi
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

# Wrapper that records any attempt to run the Management API fallback resolver
# (and refuses to run it), while delegating every other python3 call.
wrap_bin="$tmp/wrap"
mkdir -p "$wrap_bin"
cat > "$wrap_bin/python3" <<WRAP_PY
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == *resolve-current-pr-preview-ref-from-branches.py ]]; then
    echo FALLBACK_INVOKED >> "\${FALLBACK_LOG:?}"
    exit 1
  fi
done
exec "$real_python" "\$@"
WRAP_PY
chmod +x "$wrap_bin/python3"
fallback_log="$tmp/fallback.log"
: > "$fallback_log"

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

good_config=$'[edge_runtime.secrets]\nGEMINI_API_KEY = "env(GEMINI_API_KEY)"\nWA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"\n'

make_sandbox() { # dir pubkey
  local dir="$1" pub="$2"
  mkdir -p "$dir/scripts" "$dir/supabase"
  cp scripts/verify-preview-dotenv-crypto-authority.sh scripts/check-preview-hosted-proof-preconditions.sh \
     scripts/verify-preview-env-decryptable.sh "$dir/scripts/"
  cat > "$dir/supabase/.env.preview" <<PREVIEW
DOTENV_PUBLIC_KEY_PREVIEW="$pub"
GEMINI_API_KEY="encrypted:AAAAsynthetic"
WA_STAGE1B_CERT_SECRET="encrypted:BBBBsynthetic"
PREVIEW
  printf '%s' "$good_config" > "$dir/supabase/config.toml"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@test.local -c user.name=t commit -qm base
}

run_script_in() { # dir script [VAR=value ...] -> combined output, status preserved
  local dir="$1" script="$2"; shift 2
  (cd "$dir" && env -i PATH="$mock_bin:$PATH" HOME="$tmp" GIT_CONFIG_GLOBAL=/dev/null \
      MOCK_NETWORK_LOG="$network_log" "$@" bash "scripts/$script") 2>&1
}
expect_script_fail() { # name script expected-code dir [env...]
  local name="$1" script="$2" code="$3" dir="$4"; shift 4
  local output status=0
  output="$(run_script_in "$dir" "$script" "$@")" || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: unexpectedly passed"
  grep -Fq "$code" <<<"$output" || fail "$name: expected $code, got: $(head -c 300 <<<"$output")"
  ! grep -Eq 'authority_mode=|hosted_proof_preconditions=ok' <<<"$output" || fail "$name: reported success despite failing"
  pass_case
}
expect_script_pass() { # name script expected-line dir [env...]
  local name="$1" script="$2" line="$3" dir="$4"; shift 4
  local output status=0
  output="$(run_script_in "$dir" "$script" "$@")" || status=$?
  [[ "$status" -eq 0 ]] || fail "$name: unexpectedly failed: $(head -c 300 <<<"$output")"
  grep -Fxq "$line" <<<"$output" || fail "$name: expected line $line"
  pass_case
}
authority=verify-preview-dotenv-crypto-authority.sh
preconditions=check-preview-hosted-proof-preconditions.sh

# --- 1. protected workflow only: independent key, strict, no fall-through ---
s1="$tmp/s1"; make_sandbox "$s1" "$pub_a"
expect_script_pass 'matching key + decrypt' "$authority" authority_mode=independent_key "$s1" \
  PREVIEW_DOTENV_PRIVATE_KEY="$key_a" MOCK_DOTENVX_RESULT=ok
[[ ! -e "$s1/supabase/.env.keys" ]] || fail 'verifier left a key file behind'
expect_script_fail 'wrong key (valid format) with decrypt lying OK' "$authority" PUBLIC_KEY_MISMATCH "$s1" \
  PREVIEW_DOTENV_PRIVATE_KEY="$key_b" MOCK_DOTENVX_RESULT=ok
expect_script_fail 'matching key but decrypt fails' "$authority" DECRYPT_FAILED "$s1" \
  PREVIEW_DOTENV_PRIVATE_KEY="$key_a" MOCK_DOTENVX_RESULT=fail
[[ ! -e "$s1/supabase/.env.keys" ]] || fail 'verifier left a key file after a failed decrypt'
expect_script_fail 'malformed key' "$authority" KEY_FORMAT_INVALID "$s1" PREVIEW_DOTENV_PRIVATE_KEY='not-a-hex-key'
expect_script_fail 'truncated key' "$authority" KEY_FORMAT_INVALID "$s1" PREVIEW_DOTENV_PRIVATE_KEY="${key_a:0:62}"
: > "$network_log"
expect_script_fail 'no key: required, never read back from Supabase' "$authority" KEY_REQUIRED "$s1" \
  SUPABASE_ACCESS_TOKEN=present-token PRODUCTION_PROJECT_REF="$prod_ref" HTTPS_PROXY=http://127.0.0.1:9
[[ ! -s "$network_log" ]] || fail 'verifier invoked a network or Supabase CLI client'
s_missing="$tmp/s-missing"; make_sandbox "$s_missing" "$pub_a"; rm -f "$s_missing/supabase/.env.preview"
expect_script_fail 'ciphertext file missing' "$authority" ENV_PREVIEW_MISSING "$s_missing" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"
s_plain="$tmp/s-plain"; make_sandbox "$s_plain" "$pub_a"
sed -i 's/^GEMINI_API_KEY=.*/GEMINI_API_KEY="plaintext-value"/' "$s_plain/supabase/.env.preview"
expect_script_fail 'plaintext entry' "$authority" GEMINI_API_KEY_NOT_ENCRYPTED "$s_plain" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"
s_nohdr="$tmp/s-nohdr"; make_sandbox "$s_nohdr" "$pub_a"
sed -i '/^DOTENV_PUBLIC_KEY_PREVIEW=/d' "$s_nohdr/supabase/.env.preview"
expect_script_fail 'public key header missing' "$authority" PUBLIC_KEY_HEADER_MISSING_OR_INVALID "$s_nohdr" PREVIEW_DOTENV_PRIVATE_KEY="$key_a"

# --- 2. offline hosted-proof preconditions (no credentials, no network) -----
: > "$network_log"
expect_script_pass 'preconditions hold' "$preconditions" hosted_proof_preconditions=ok "$s1"
s_nocfg="$tmp/p-nocfg"; make_sandbox "$s_nocfg" "$pub_a"; rm -f "$s_nocfg/supabase/config.toml"
expect_script_fail 'config.toml missing' "$preconditions" CONFIG_MISSING "$s_nocfg"
s_nosec="$tmp/p-nosec"; make_sandbox "$s_nosec" "$pub_a"
printf '[api]\nenabled = true\n' > "$s_nosec/supabase/config.toml"
expect_script_fail 'preview that never references the secrets proves nothing' "$preconditions" CONFIG_SECRETS_NOT_DECLARED "$s_nosec"
s_onedecl="$tmp/p-onedecl"; make_sandbox "$s_onedecl" "$pub_a"
printf '[edge_runtime.secrets]\nGEMINI_API_KEY = "env(GEMINI_API_KEY)"\n' > "$s_onedecl/supabase/config.toml"
expect_script_fail 'one env() declaration missing' "$preconditions" CONFIG_SECRETS_NOT_DECLARED "$s_onedecl"
s_nosection="$tmp/p-nosection"; make_sandbox "$s_nosection" "$pub_a"
printf 'GEMINI_API_KEY = "env(GEMINI_API_KEY)"\nWA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"\n' > "$s_nosection/supabase/config.toml"
expect_script_fail 'edge_runtime.secrets section missing' "$preconditions" CONFIG_SECRETS_NOT_DECLARED "$s_nosection"
s_pplain="$tmp/p-plain"; make_sandbox "$s_pplain" "$pub_a"
sed -i 's/^WA_STAGE1B_CERT_SECRET=.*/WA_STAGE1B_CERT_SECRET="plaintext-value"/' "$s_pplain/supabase/.env.preview"
expect_script_fail 'plaintext value would pass a hosted check while proving nothing' "$preconditions" WA_STAGE1B_CERT_SECRET_NOT_ENCRYPTED "$s_pplain"
s_pmissing="$tmp/p-missing"; make_sandbox "$s_pmissing" "$pub_a"; rm -f "$s_pmissing/supabase/.env.preview"
expect_script_fail 'ciphertext file missing' "$preconditions" ENV_PREVIEW_MISSING "$s_pmissing"
s_phdr="$tmp/p-hdr"; make_sandbox "$s_phdr" "$pub_a"; sed -i '/^DOTENV_PUBLIC_KEY_PREVIEW=/d' "$s_phdr/supabase/.env.preview"
expect_script_fail 'public key header missing' "$preconditions" PUBLIC_KEY_HEADER_MISSING_OR_INVALID "$s_phdr"
s_ppriv="$tmp/p-priv"; make_sandbox "$s_ppriv" "$pub_a"
printf 'DOTENV_PRIVATE_KEY_PREVIEW="%s"\n' "$key_a" >> "$s_ppriv/supabase/.env.preview"
expect_script_fail 'private key committed in the ciphertext file' "$preconditions" PRIVATE_KEY_IN_CIPHERTEXT_FILE "$s_ppriv"
! grep -Fq "$key_a" <<<"$(run_script_in "$s_ppriv" "$preconditions" 2>&1 || true)" || fail 'preconditions script echoed key material'
s_ptracked="$tmp/p-tracked"; make_sandbox "$s_ptracked" "$pub_a"
printf 'x\n' > "$s_ptracked/supabase/.env.keys"; git -C "$s_ptracked" add -f supabase/.env.keys
expect_script_fail 'private key file tracked by Git' "$preconditions" PRIVATE_KEY_FILE_TRACKED "$s_ptracked"
[[ ! -s "$network_log" ]] || fail 'preconditions script contacted the network'

# --- 3. hosted preview resolution: unprivileged, GitHub check-run only ------
cat > "$tmp/mock_api.py" <<'MOCK_API'
import http.server, json, sys

routes_path = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def _log(self, kind):
        with open(routes_path + ".log", "a", encoding="utf-8") as handle:
            handle.write(f"{kind} {self.path} auth={'yes' if self.headers.get('Authorization') else 'no'}\n")

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
"$real_python" "$tmp/mock_api.py" "$routes" > "$tmp/port" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
port="$(cat "$tmp/port")"
[[ "$port" =~ ^[0-9]+$ ]] || fail 'mock GitHub API did not start'
api="http://127.0.0.1:$port"
repo_slug='oasisbaklawa2006/oasis-supabase-core'
head_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
preview_a='abcdefghijklmnopqrst'
preview_b='zyxwvutsrqponmlkjihg'

run_json() { # name status conclusion app_id app_slug details_url
  printf '{"name":"%s","status":"%s","conclusion":%s,"app":{"id":%s,"slug":"%s"},"details_url":"%s","id":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:-1001}"
}
set_checks() { # json-run [json-run ...]
  "$real_python" - "$routes" "$repo_slug" "$head_sha" "$@" <<'PY'
import json, sys
path, repo, sha, *runs = sys.argv[1:]
payload = {"check_runs": [json.loads(r) for r in runs]}
base = f"/repos/{repo}/commits/{sha}/check-runs"
routes = {f"{base}?per_page=100": payload, f"{base}?per_page=100&page=1": payload}
open(path, "w").write(json.dumps(routes))
PY
  : > "$routes.log"; : > "$fallback_log"
}
hosted_run() { # [extra env...] -> output; status preserved
  env -i PATH="$wrap_bin:$PATH" HOME="$tmp" FALLBACK_LOG="$fallback_log" \
    GITHUB_REPOSITORY="$repo_slug" GITHUB_PR_HEAD_SHA="$head_sha" GH_TOKEN=read-only-github-token \
    GITHUB_API_URL="$api" PREVIEW_REF_WAIT_ATTEMPTS=1 PREVIEW_REF_WAIT_SECONDS=0 "$@" \
    bash scripts/wait-for-current-pr-preview-ref.sh 2>&1
}
expect_hosted_fail() { # name expected-text [env...]
  local name="$1" text="$2"; shift 2
  local output status=0
  output="$(hosted_run "$@")" || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: hosted preview unexpectedly resolved"
  grep -Fq "$text" <<<"$output" || fail "$name: expected '$text', got: $(head -c 300 <<<"$output")"
  ! grep -Eq '^[a-z0-9]{20}$' <<<"$output" || fail "$name: printed a preview ref despite failing"
  [[ ! -s "$fallback_log" ]] || fail "$name: invoked the Management API fallback"
  pass_case
}
dash="https://supabase.com/dashboard/project"
trusted="$(run_json 'Supabase Preview' completed '"success"' 330661 supabase "$dash/$preview_a")"

set_checks "$trusted"
out="$(hosted_run GITHUB_HEAD_REF=feature/pr SUPABASE_ACCESS_TOKEN= )"
[[ "$out" == "$preview_a" ]] || fail "trusted hosted success must resolve the preview ref, got: $out"
! grep -q '^WRITE' "$routes.log" || fail 'resolution issued a non-GET request'
grep -Fq 'auth=yes' "$routes.log" || fail 'resolution did not authenticate with the GitHub token'
[[ ! -s "$fallback_log" ]] || fail 'resolution invoked the Management API fallback without a Supabase token'
! grep -v -E "^GET /repos/${repo_slug}/commits/${head_sha}/check-runs\?per_page=100" "$routes.log" | grep -q . \
  || fail 'resolution contacted an unexpected endpoint'
pass_case

set_checks "$(run_json 'Supabase Preview' completed '"skipped"' 330661 supabase "$dash/$prod_ref/branches")"
expect_hosted_fail 'integration skipped (e.g. concurrent branch limit) is BLOCKED, not success' PREVIEW_NOT_PROVISIONED \
  GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"failure"' 330661 supabase "$dash/$preview_a")"
expect_hosted_fail 'hosted decryption/deploy failure' PREVIEW_TERMINAL_STATE GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"cancelled"' 330661 supabase "$dash/$preview_a")"
expect_hosted_fail 'hosted check cancelled' PREVIEW_TERMINAL_STATE GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' in_progress null 330661 supabase "$dash/$preview_a")"
expect_hosted_fail 'hosted check still running at the deadline' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks
expect_hosted_fail 'no hosted check at all' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 15368 github-actions "$dash/$preview_a")"
expect_hosted_fail 'success published by another app (id and slug)' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 330661 github-actions "$dash/$preview_a")"
expect_hosted_fail 'success with the right id but another slug' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 15368 supabase "$dash/$preview_a")"
expect_hosted_fail 'success with the right slug but another id' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Some Other Check' completed '"success"' 330661 supabase "$dash/$preview_a")"
expect_hosted_fail 'success under another check name' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 330661 supabase "$dash/$prod_ref")"
expect_hosted_fail 'details_url naming the production project ref' 'production project ref is forbidden' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 330661 supabase "http://supabase.com/dashboard/project/$preview_a")"
expect_hosted_fail 'details_url over plain http' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$(run_json 'Supabase Preview' completed '"success"' 330661 supabase "https://evil.example/dashboard/project/$preview_a")"
expect_hosted_fail 'details_url on another host' 'did not identify' GITHUB_HEAD_REF=feature/pr
set_checks "$trusted" "$(run_json 'Supabase Preview' completed '"success"' 330661 supabase "$dash/$preview_b" 1002)"
expect_hosted_fail 'two different successful previews are ambiguous' 'did not identify exactly one' GITHUB_HEAD_REF=feature/pr
expect_hosted_fail 'missing GitHub token' 'GH_TOKEN is required' GH_TOKEN=
# The wait script must fail closed when GitHub is unreachable, too.
expect_hosted_fail 'GitHub API unavailable' 'check-run lookup failed' GITHUB_API_URL="http://127.0.0.1:9"

# Positive control: the harness really detects the privileged Management API
# fallback, which exists only when a Supabase token AND a head ref are present.
# The readiness job holds neither the token nor (by gate) any path to it.
set_checks "$(run_json 'Supabase Preview' completed '"skipped"' 330661 supabase "$dash/$prod_ref/branches")"
hosted_run GITHUB_HEAD_REF=feature/pr SUPABASE_ACCESS_TOKEN=would-be-privileged >/dev/null 2>&1 || true
grep -Fq FALLBACK_INVOKED "$fallback_log" || fail 'harness failed to detect the Management API fallback (positive control)'
pass_case

# --- 4. readiness probe stays fail-closed -----------------------------------
probe_sandbox="$tmp/probe"
mkdir -p "$probe_sandbox/scripts"
cp scripts/check-preview-edge-runtime-secrets-readiness.sh scripts/resolve-current-pr-preview-ref.sh \
   scripts/resolve-current-pr-preview-ref-from-branches.py "$probe_sandbox/scripts/"
git -C "$probe_sandbox" init -q
probe() { # [env...] -> output; status preserved
  (cd "$probe_sandbox" && env -i PATH="$mock_bin:$PATH" HOME="$tmp" GIT_CONFIG_GLOBAL=/dev/null \
    MOCK_NETWORK_LOG="$network_log" "$@" bash scripts/check-preview-edge-runtime-secrets-readiness.sh) 2>&1
}
expect_probe_fail() { # name expected-text [env...]
  local name="$1" text="$2"; shift 2
  local output status=0
  output="$(probe "$@")" || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: probe unexpectedly passed"
  grep -Fq "$text" <<<"$output" || fail "$name: expected '$text', got: $(head -c 300 <<<"$output")"
  pass_case
}
: > "$network_log"
expect_probe_fail 'no cert secret' WA_STAGE1B_CERT_SECRET_REQUIRED
expect_probe_fail 'malformed preview ref' 'invalid preview ref' WA_STAGE1B_CERT_SECRET=s WA_STAGE1B_PREVIEW_REF=NOT-A-REF
expect_probe_fail 'production ref is never a certification target' 'production project ref forbidden' \
  WA_STAGE1B_CERT_SECRET=s WA_STAGE1B_PREVIEW_REF="$prod_ref"
expect_probe_fail 'no ref and no GitHub context: no historical fallback' 'GITHUB_REPOSITORY is required' WA_STAGE1B_CERT_SECRET=s
[[ ! -s "$network_log" ]] || fail 'probe sent a request before its guards passed'
expect_probe_fail 'runtime without the GEMINI secret is not certified' 'GEMINI_API_KEY unavailable' \
  WA_STAGE1B_CERT_SECRET=s WA_STAGE1B_PREVIEW_REF="$preview_a" MOCK_CURL_BODY='{"GEMINI_API_KEY_EDGE_RUNTIME":false}'
probe_ok="$(probe WA_STAGE1B_CERT_SECRET=s WA_STAGE1B_PREVIEW_REF="$preview_a" MOCK_CURL_BODY='{"GEMINI_API_KEY_EDGE_RUNTIME":true}')"
grep -Fq "Preview Edge Runtime secret readiness verified for ${preview_a}" <<<"$probe_ok" || fail 'probe did not certify a ready preview'
! grep -Fq 'api.supabase.com' "$network_log" || fail 'probe contacted the Management API'
pass_case

# --- 5. the key can be written only by the protected rotation path ----------
for event in pull_request pull_request_target; do
  writer_status=0
  writer_out="$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" GITHUB_EVENT_NAME="$event" PREVIEW_KEY_ROTATION_AUTHORIZED=true \
    PRODUCTION_PROJECT_REF="$prod_ref" SUPABASE_ACCESS_TOKEN=t PREVIEW_DOTENV_PRIVATE_KEY="$key_a" \
    python3 "$repo_root/scripts/upload-production-dotenvx-key.py" 2>&1)" || writer_status=$?
  [[ "$writer_status" -ne 0 ]] && grep -Fq PREVIEW_KEY_WRITE_FORBIDDEN <<<"$writer_out" || fail "key writer ran in a $event context"
  pass_case
done
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

# --- 6. no Management API readback anywhere ---------------------------------
: > "$network_log"
load_out="$(cd "$tmp" && mkdir -p loadbox/supabase && cd loadbox && git init -q . 2>/dev/null; \
  env -i PATH="$mock_bin:$PATH" HOME="$tmp" MOCK_NETWORK_LOG="$network_log" SUPABASE_ACCESS_TOKEN=present-token \
  PRODUCTION_PROJECT_REF="$prod_ref" bash "$repo_root/scripts/load-preview-dotenvx-keys.sh" 2>&1)"
[[ "$load_out" == 'no_production_dotenvx_private_key' ]] || fail "key loader returned an unexpected state"
[[ ! -s "$network_log" ]] || fail 'key loader contacted Supabase or the network'
pass_case
[[ ! -e scripts/fetch-production-dotenv-private-key.py ]] || fail 'readback script exists'
[[ ! -e scripts/verify-preview-dotenv-attestation.py && ! -e supabase/.env.preview.attestations.json ]] \
  || fail 'key-free attestation bypass exists'
pass_case

# --- 7. static gate: credential isolation over every workflow ---------------
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
rogue_pr() { # secrets-line-or-empty  extra-job-lines
  cat > "$mutated/.github/workflows/rogue.yml" <<ROGUE
name: rogue
on:
  pull_request:
    branches: [main]
jobs:
  x:
$2
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
        env:
          V: $1
ROGUE
}

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n",
              "          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness job receives the write-capable Supabase token' 'without a protected environment'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n",
              "          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n          K: ${{ secrets.PREVIEW_DOTENV_PRIVATE_KEY }}\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness job receives the dotenvx private key' 'without a protected environment'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n",
              "          GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}\n          GITHUB_HEAD_REF: ${{ github.head_ref }}\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness job re-arms the Management API fallback inputs' 'hold no Supabase credential'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          preview_ref=\"$(bash scripts/wait-for-current-pr-preview-ref.sh)\"\n",
              "          bash scripts/ensure-supabase-preview-branch.sh\n          preview_ref=\"$(bash scripts/wait-for-current-pr-preview-ref.sh)\"\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness job creates preview branches via the Management API' 'must not invoke privileged'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("        run: bash scripts/check-preview-edge-runtime-secrets-readiness.sh\n",
              "        run: bash scripts/check-preview-edge-runtime-secrets-readiness.sh || true\n", 1)
s = s.replace("scripts/wait-for-current-pr-preview-ref.sh", "scripts/resolve-x.sh")
open(p, 'w').write(s)
PY
expect_gate_rejects 'readiness stops resolving the hosted preview ref' 'readiness must resolve the preview ref'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          bash scripts/check-preview-hosted-proof-preconditions.sh\n",
              "          bash scripts/check-preview-hosted-proof-preconditions.sh\n          echo ${{ secrets.WA_STAGE1B_CERT_SECRET }}\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'provision job gains a secret' 'credential-free'

fresh_copy; python3 - "$mutated/$gov" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          bash scripts/check-preview-hosted-proof-preconditions.sh\n",
              "          bash scripts/check-preview-hosted-proof-preconditions.sh\n          git push origin HEAD\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'provision job pushes to Git' 'credential-free'

fresh_copy; sed -i 's/^  contents: read$/  contents: write/' "$mutated/$gov"
expect_gate_rejects 'governance workflow regains contents: write' 'contents'

fresh_copy; sed -i "s/(needs.path-scope.outputs.edge_runtime != 'true' || needs.provision-preview-dotenv.result == 'success')/(needs.provision-preview-dotenv.result == 'success' || needs.provision-preview-dotenv.result == 'skipped')/" "$mutated/$gov"
expect_gate_rejects 'readiness may run without the offline preconditions' 'readiness must run only after'

fresh_copy; rogue_pr "\${{ secrets.SUPABASE_DB_URL }}" ""
expect_gate_rejects 'a PR workflow reads the production database URL' 'without a protected environment'
fresh_copy; rogue_pr "\${{ secrets.GEMINI_API_KEY }}" ""
expect_gate_rejects 'a PR workflow reads the Gemini provider key' 'without a protected environment'
fresh_copy; rogue_pr "\${{ secrets.SOME_OTHER_SECRET }}" ""
expect_gate_rejects 'a PR workflow reads an unlisted secret' 'only the cert-runner probe secret is allowed'
fresh_copy; rogue_pr "plain" "    environment: supabase-production"
expect_gate_rejects 'a PR workflow binds a protected environment' 'must not bind a GitHub environment'
fresh_copy; rogue_pr "plain" "    uses_note: x"; sed -i 's/^  pull_request:/  pull_request_target:/' "$mutated/.github/workflows/rogue.yml"
expect_gate_rejects 'pull_request_target is introduced' 'pull_request_target'
fresh_copy; rogue_pr "plain" ""; printf '    secrets: inherit\n' >> "$mutated/.github/workflows/rogue.yml"
expect_gate_rejects 'secrets: inherit is introduced' 'reusable workflows'
fresh_copy; rogue_pr "plain" ""; sed -i 's/^on:/on:\n  workflow_call:/' "$mutated/.github/workflows/rogue.yml"
expect_gate_rejects 'a reusable workflow is introduced' 'reusable workflows'
fresh_copy; rogue_pr "plain" ""; printf '      - run: bash scripts/upload-preview-dotenvx-keys.sh\n' >> "$mutated/.github/workflows/rogue.yml"
expect_gate_rejects 'a PR workflow invokes the key uploader' 'must not invoke privileged'
fresh_copy; rogue_pr "plain" ""; printf '      - run: curl https://api.supabase.com/v1/projects\n' >> "$mutated/.github/workflows/rogue.yml"
expect_gate_rejects 'a PR workflow calls the Management API' 'must not invoke privileged'
fresh_copy; python3 - "$mutated/.github/workflows/auto-production-migration-dispatch.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("          GH_TOKEN: ${{ github.token }}\n", "          GH_TOKEN: ${{ github.token }}\n          LEAK: ${{ secrets.SOME_SECRET }}\n", 1)
open(p, 'w').write(s)
PY
expect_gate_rejects 'a workflow_run workflow reads repository secrets' 'workflow_run-triggered'
fresh_copy; python3 - "$mutated/.github/workflows/production-migration-release.yml" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s2 = s.replace("    environment: supabase-production\n", "", 1)
assert s2 != s, "production job environment line not found"
open(p, 'w').write(s2)
PY
expect_gate_rejects 'a production job loses its protected environment' 'without a protected environment'

# --- 8. protected key-maintenance workflow ----------------------------------
fresh_copy; sed -i 's/NEW_PREVIEW_DOTENVX_KEY_REQUIRES_PERSISTED_CIPHERTEXT/SOMETHING_ELSE/' "$mutated/$sync"
expect_gate_rejects 'sync workflow may publish a newly generated key' 'newly generated key'
fresh_copy; sed -i "/github.ref == 'refs\/heads\/main'/d" "$mutated/$sync"
expect_gate_rejects 'sync workflow may run from a non-main branch' 'main branch'
fresh_copy; python3 - "$mutated/$sync" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  workflow_dispatch:\n", "  pull_request:\n    types: [opened]\n  workflow_dispatch:\n", 1)
open(p, 'w').write(s)
PY2
expect_gate_rejects 'sync workflow regains a pull_request trigger' 'must not bind a GitHub environment'
fresh_copy; sed -i "/^    environment: supabase-preview-key-authority$/d" "$mutated/$sync"
expect_gate_rejects 'sync job loses its protected environment' 'without a protected environment'
fresh_copy; sed -i "s/&& inputs.rotation_authorization == 'AUTHORIZE-PREVIEW-DOTENVX-KEY-ROTATION'//" "$mutated/$sync"
expect_gate_rejects 'sync job loses explicit authorization phrase' 'authorization phrase'
fresh_copy; sed -i "s/github.event_name == 'workflow_dispatch'/github.event_name != 'workflow_dispatch'/" "$mutated/$sync"
expect_gate_rejects 'sync job runs outside workflow_dispatch' 'workflow_dispatch'
fresh_copy; sed -i 's/verify-preview-dotenv-crypto-authority\.sh/verify-nothing.sh/' "$mutated/$sync"
expect_gate_rejects 'sync job stops verifying the independent key' 'verify the independent key authority'
fresh_copy; sed -i 's/PREVIEW_KEY_ROTATION_AUTHORIZED/PREVIEW_KEY_ROTATION_X/g' "$mutated/scripts/upload-production-dotenvx-key.py"
expect_gate_rejects 'key writer loses its authorization guard' 'rotation authorization'
fresh_copy; printf '#!/usr/bin/env python3\n' > "$mutated/scripts/fetch-production-dotenv-private-key.py"
expect_gate_rejects 'readback script reintroduced' 'readback script must not exist'
fresh_copy; printf '#!/usr/bin/env python3\n' > "$mutated/scripts/verify-preview-dotenv-attestation.py"
expect_gate_rejects 'attestation bypass reintroduced' 'attestation bypass must not exist'
fresh_copy; printf 'curl -s https://api.supabase.com/v1/projects/x/secrets\n' >> "$mutated/scripts/load-preview-dotenvx-keys.sh"
expect_gate_rejects 'key loader contacts Supabase' 'local-only'

# --- 9. path scope: hardening is static-only; ciphertext needs hosted readiness
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
scope_branch hardening-only scripts/check-preview-hosted-proof-preconditions.sh
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main static)" == true ]] || fail 'hardening change must stay under static Edge governance'
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == false ]] || fail 'verifier-only change must not be misreported as runtime-certified'
scope_branch authority-only scripts/verify-preview-dotenv-crypto-authority.sh
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == false ]] || fail 'key-verifier change must not be misreported as runtime-certified'
scope_branch ciphertext-change supabase/.env.preview
[[ "$(cd "$scope" && bash scripts/detect-pr-edge-governance-paths.sh main runtime)" == true ]] || fail 'ciphertext change must require hosted Edge Runtime readiness'
pass_case

echo "verify-preview-dotenv-authority-hardening.sh: all ${cases} cases passed"
