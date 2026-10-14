#!/usr/bin/env bash
# Offline, credential-free preconditions for treating a hosted Supabase Preview
# success as proof that supabase/.env.preview decrypts.
#
# A hosted `Supabase Preview` success only exercises the dotenvx ciphertext if
# (a) supabase/config.toml actually declares the env() Edge Runtime secrets and
# (b) supabase/.env.preview carries *encrypted* values for them. A preview that
# never referenced the secrets, or plaintext values committed to Git, would pass
# the hosted check while proving nothing about key authority. This script holds
# no secret, contacts no network and never prints values.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config_file="supabase/config.toml"
preview_file="supabase/.env.preview"

fail() {
  echo "PREVIEW_HOSTED_PROOF_PRECONDITION_FAILED: $*" >&2
  exit 1
}

[[ -f "$config_file" ]] || fail "CONFIG_MISSING"
grep -Fq '[edge_runtime.secrets]' "$config_file" || fail "CONFIG_SECRETS_NOT_DECLARED"
grep -Eq '^GEMINI_API_KEY[[:space:]]*=[[:space:]]*"env\(GEMINI_API_KEY\)"[[:space:]]*$' "$config_file" \
  || fail "CONFIG_SECRETS_NOT_DECLARED"
grep -Eq '^WA_STAGE1B_CERT_SECRET[[:space:]]*=[[:space:]]*"env\(WA_STAGE1B_CERT_SECRET\)"[[:space:]]*$' "$config_file" \
  || fail "CONFIG_SECRETS_NOT_DECLARED"

[[ -f "$preview_file" ]] || fail "ENV_PREVIEW_MISSING"
grep -Eq '^GEMINI_API_KEY="?encrypted:' "$preview_file" || fail "GEMINI_API_KEY_NOT_ENCRYPTED"
grep -Eq '^WA_STAGE1B_CERT_SECRET="?encrypted:' "$preview_file" || fail "WA_STAGE1B_CERT_SECRET_NOT_ENCRYPTED"

header_public_key="$({ grep -E '^DOTENV_PUBLIC_KEY_PREVIEW=' "$preview_file" || true; } | head -n 1 | cut -d= -f2- | tr -d "\"' \r" | tr 'A-F' 'a-f')"
[[ "$header_public_key" =~ ^0[23][0-9a-f]{64}$ ]] || fail "PUBLIC_KEY_HEADER_MISSING_OR_INVALID"

# A private key must never be committed alongside the ciphertext.
if grep -Eq '^DOTENV_PRIVATE_KEY' "$preview_file"; then
  fail "PRIVATE_KEY_IN_CIPHERTEXT_FILE"
fi
if git ls-files --error-unmatch supabase/.env.keys >/dev/null 2>&1; then
  fail "PRIVATE_KEY_FILE_TRACKED"
fi

echo "hosted_proof_preconditions=ok"
