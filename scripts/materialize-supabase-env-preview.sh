#!/usr/bin/env bash
# Encrypt approved preview Edge Runtime secrets into supabase/.env.preview
# using dotenvx. Never logs, commits, or echoes secret values.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
dotenvx_version="1.44.1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "MATERIALIZE PREVIEW ENV FAILED: $*" >&2
  exit 1
}

file_fingerprint() {
  if [[ -s "$1" ]]; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

[[ -n "${GEMINI_API_KEY:-}" ]] || fail "GEMINI_API_KEY is required"
[[ -n "${WA_STAGE1B_CERT_SECRET:-}" ]] || fail "WA_STAGE1B_CERT_SECRET is required"

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  umask 077
  mkdir -p supabase
  printf 'DOTENV_PRIVATE_KEY_PREVIEW=%s\n' "$PREVIEW_DOTENV_PRIVATE_KEY" > "$keys_file"
  echo "::add-mask::${PREVIEW_DOTENV_PRIVATE_KEY}" >&2
fi

echo "::add-mask::${GEMINI_API_KEY}" >&2
echo "::add-mask::${WA_STAGE1B_CERT_SECRET}" >&2

mkdir -p supabase
if [[ -f "$preview_file" ]] \
  && grep -Fq "encrypted:" "$preview_file" \
  && grep -Fq "GEMINI_API_KEY=" "$preview_file" \
  && grep -Fq "WA_STAGE1B_CERT_SECRET=" "$preview_file"; then
  if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
    if bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
      echo "existing_encrypted_preview_env"
      exit 0
    fi
    rm -f "$preview_file"
  elif [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    resolved="$(PRODUCTION_PROJECT_REF="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}" \
      SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" \
      python3 "$script_dir/fetch-production-dotenv-private-key.py" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      umask 077
      printf 'DOTENV_PRIVATE_KEY_PREVIEW="%s"\n' "$resolved" > "$keys_file"
      echo "::add-mask::$resolved" >&2
      if bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
        echo "existing_encrypted_preview_env"
        exit 0
      fi
      # A named production secret that cannot decrypt the committed payload is
      # stale/unusable authority. Remove both payload and key so dotenvx creates
      # one coherent fresh pair; the workflow will then publish that key through
      # the governed production-authority uploader before claiming readiness.
      rm -f "$preview_file" "$keys_file"
    else
      rm -f "$preview_file" "$keys_file"
    fi
  else
    rm -f "$preview_file" "$keys_file"
  fi
fi

if [[ ! -f "$preview_file" ]]; then
  printf '# Supabase preview Edge Runtime secrets (dotenvx encrypted)\n' > "$preview_file"
fi

key_state="$(bash "$script_dir/load-preview-dotenvx-keys.sh")"
generated_new_keys=false
if [[ "$key_state" == "no_production_dotenvx_private_key" && ! -s "$keys_file" ]]; then
  generated_new_keys=true
fi
key_fingerprint_before="$(file_fingerprint "$keys_file")"

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set GEMINI_API_KEY "$GEMINI_API_KEY" -f "$preview_file" >/dev/null
npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set WA_STAGE1B_CERT_SECRET "$WA_STAGE1B_CERT_SECRET" -f "$preview_file" >/dev/null

[[ -f "$preview_file" ]] || fail "$preview_file was not created"
[[ -f "$keys_file" ]] || fail "$keys_file was not created"

key_fingerprint_after="$(file_fingerprint "$keys_file")"
if [[ "$key_fingerprint_before" != "$key_fingerprint_after" || "$key_fingerprint_before" == "missing" ]]; then
  # Fresh/replaced key material is not production authority until the governed
  # uploader publishes and re-verifies it in the same workflow.
  generated_new_keys=true
fi

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
