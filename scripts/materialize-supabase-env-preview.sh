#!/usr/bin/env bash
# Encrypt approved preview Edge Runtime secrets into supabase/.env.preview
# using dotenvx. Never logs, commits, or echoes secret values.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
dotenvx_version="1.44.1"
script_dir="$(dirname "$0")"

fail() {
  echo "MATERIALIZE PREVIEW ENV FAILED: $*" >&2
  exit 1
}

[[ -n "${GEMINI_API_KEY:-}" ]] || fail "GEMINI_API_KEY is required"
[[ -n "${WA_STAGE1B_CERT_SECRET:-}" ]] || fail "WA_STAGE1B_CERT_SECRET is required"

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  umask 077
  mkdir -p supabase
  printf 'DOTENV_PRIVATE_KEY_PREVIEW="%s"\n' "$PREVIEW_DOTENV_PRIVATE_KEY" > "$keys_file"
  echo "::add-mask::${PREVIEW_DOTENV_PRIVATE_KEY}"
fi

echo "::add-mask::${GEMINI_API_KEY}"
echo "::add-mask::${WA_STAGE1B_CERT_SECRET}"

mkdir -p supabase
if [[ -f "$preview_file" ]] \
  && grep -Fq "encrypted:" "$preview_file" \
  && grep -Fq "GEMINI_API_KEY=" "$preview_file" \
  && grep -Fq "WA_STAGE1B_CERT_SECRET=" "$preview_file"; then
  echo "existing_encrypted_preview_env"
  exit 0
fi

if [[ ! -f "$preview_file" ]]; then
  printf '# Supabase preview Edge Runtime secrets (dotenvx encrypted)\n' > "$preview_file"
fi

key_state="$(bash "$script_dir/load-preview-dotenvx-keys.sh")"
generated_new_keys=false
if [[ "$key_state" == "no_production_dotenvx_private_key" && ! -s "$keys_file" ]]; then
  generated_new_keys=true
fi

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set GEMINI_API_KEY "$GEMINI_API_KEY" -f "$preview_file" >/dev/null
npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set WA_STAGE1B_CERT_SECRET "$WA_STAGE1B_CERT_SECRET" -f "$preview_file" >/dev/null

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

if [[ "$generated_new_keys" == true ]]; then
  echo "generated_new_dotenvx_keys"
else
  echo "materialized_encrypted_preview_env"
fi
