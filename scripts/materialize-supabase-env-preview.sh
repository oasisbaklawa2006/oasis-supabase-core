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

has_encrypted_assignment() {
  local name="$1"
  grep -Eq "^${name}=\"?encrypted:" "$preview_file"
}

[[ -n "${GEMINI_API_KEY:-}" ]] || fail "GEMINI_API_KEY is required"
[[ -n "${WA_STAGE1B_CERT_SECRET:-}" ]] || fail "WA_STAGE1B_CERT_SECRET is required"

force_new_keys=false

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
  && has_encrypted_assignment GEMINI_API_KEY \
  && has_encrypted_assignment WA_STAGE1B_CERT_SECRET; then
  if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
    if bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
      echo "existing_encrypted_preview_env"
      exit 0
    fi
    rm -f "$preview_file" "$keys_file"
    force_new_keys=true
  elif [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    # Supabase production secrets are treated as write-only authority. A
    # successful names-only authority check is sufficient to reuse a committed
    # encrypted preview payload; the preview runtime probe proves deployment.
    if PRODUCTION_PROJECT_REF="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}" \
      SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" \
      bash "$script_dir/verify-production-dotenvx-authority.sh" >/dev/null 2>&1; then
      echo "existing_encrypted_preview_env"
      exit 0
    fi
    rm -f "$preview_file" "$keys_file"
    force_new_keys=true
  else
    rm -f "$preview_file" "$keys_file"
    force_new_keys=true
  fi
fi

if [[ ! -f "$preview_file" ]]; then
  printf '# Supabase preview Edge Runtime secrets (dotenvx encrypted)\n' > "$preview_file"
fi

generated_new_keys=false
if [[ "$force_new_keys" == true ]]; then
  rm -f "$keys_file"
  key_state="missing_production_dotenvx_authority"
  generated_new_keys=true
else
  key_state="$(bash "$script_dir/load-preview-dotenvx-keys.sh")"
  if [[ "$key_state" == "no_production_dotenvx_private_key" && ! -s "$keys_file" ]]; then
    generated_new_keys=true
  fi
fi
key_fingerprint_before="$(file_fingerprint "$keys_file")"

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set GEMINI_API_KEY "$GEMINI_API_KEY" -f "$preview_file" >/dev/null
npx --yes "@dotenvx/dotenvx@${dotenvx_version}" set WA_STAGE1B_CERT_SECRET "$WA_STAGE1B_CERT_SECRET" -f "$preview_file" >/dev/null

[[ -f "$preview_file" ]] || fail "$preview_file was not created"
[[ -f "$keys_file" ]] || fail "$keys_file was not created"

key_fingerprint_after="$(file_fingerprint "$keys_file")"
if [[ "$key_fingerprint_before" != "$key_fingerprint_after" || "$key_fingerprint_before" == "missing" ]]; then
  generated_new_keys=true
fi

has_encrypted_assignment GEMINI_API_KEY \
  || fail "GEMINI_API_KEY must be encrypted in $preview_file"
has_encrypted_assignment WA_STAGE1B_CERT_SECRET \
  || fail "WA_STAGE1B_CERT_SECRET must be encrypted in $preview_file"

# Always prove locally that the exact encrypted payload can be decrypted by the
# exact local key that will be uploaded/used for this materialization.
if ! bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
  fail "generated preview environment is not decryptable by its local authority"
fi

if [[ "$generated_new_keys" == true ]]; then
  echo "generated_new_dotenvx_keys"
else
  echo "materialized_encrypted_preview_env"
fi
