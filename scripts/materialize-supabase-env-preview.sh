#!/usr/bin/env bash
# Encrypt approved preview Edge Runtime secrets into supabase/.env.preview
# using dotenvx. Never logs, commits, or echoes secret values.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
dotenvx_version="1.44.1"

fail() {
  echo "MATERIALIZE PREVIEW ENV FAILED: $*" >&2
  exit 1
}

[[ -n "${GEMINI_API_KEY:-}" ]] || fail "GEMINI_API_KEY is required"
[[ -n "${WA_STAGE1B_CERT_SECRET:-}" ]] || fail "WA_STAGE1B_CERT_SECRET is required"

echo "::add-mask::${GEMINI_API_KEY}"
echo "::add-mask::${WA_STAGE1B_CERT_SECRET}"

mkdir -p supabase
if [[ ! -s "$preview_file" ]]; then
  printf '# Supabase preview Edge Runtime secrets (dotenvx encrypted)\n' > "$preview_file"
fi

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set GEMINI_API_KEY "$GEMINI_API_KEY" -f "$preview_file"
npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set WA_STAGE1B_CERT_SECRET "$WA_STAGE1B_CERT_SECRET" -f "$preview_file"

[[ -f "$preview_file" ]] || fail "$preview_file was not created"
[[ -f "$keys_file" ]] || fail "$keys_file was not created"

grep -Fq "encrypted:" "$preview_file" \
  || fail "$preview_file must contain dotenvx encrypted values"
grep -Fq "GEMINI_API_KEY=" "$preview_file" \
  || fail "GEMINI_API_KEY entry missing from $preview_file"
grep -Fq "WA_STAGE1B_CERT_SECRET=" "$preview_file" \
  || fail "WA_STAGE1B_CERT_SECRET entry missing from $preview_file"

if grep -E 'GEMINI_API_KEY=(sk-|AIza|[A-Za-z0-9+/=]{20,})' "$preview_file" \
  | grep -vq 'encrypted:'; then
  fail "$preview_file must not contain plaintext GEMINI_API_KEY"
fi

echo "materialized_encrypted_preview_env"
