#!/usr/bin/env bash
# Ensure production holds dotenvx preview decryption authority for branching.
# Fresh keys are verified locally before/after upload; existing ciphertext requires
# cryptographic decrypt proof (never name-only production authority).
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

keys_file="supabase/.env.keys"
preview_file="supabase/.env.preview"
production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"
script_dir="$(dirname "$0")"

fail() {
  echo "UPLOAD PREVIEW DOTENVX KEYS FAILED: $*" >&2
  exit 1
}

cleanup_local_preview_materialization() {
  rm -f "$preview_file" "$keys_file"
}

has_encrypted_assignment() {
  local name="$1"
  grep -Eq "^${name}=\"?encrypted:" "$preview_file"
}

verify_authority() {
  PRODUCTION_PROJECT_REF="$production_ref" \
    SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-}" \
    bash "$script_dir/verify-production-dotenvx-authority.sh"
}

upload_authority() {
  if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" || -s "$keys_file" ]]; then
    PRODUCTION_PROJECT_REF="$production_ref" \
      SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-}" \
      PREVIEW_DOTENV_PRIVATE_KEY="${PREVIEW_DOTENV_PRIVATE_KEY:-}" \
      DOTENV_KEYS_FILE="$keys_file" \
      python3 "$script_dir/upload-production-dotenvx-key.py"
    return $?
  fi
  return 1
}

[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] \
  || fail "SUPABASE_ACCESS_TOKEN is required to verify production dotenvx authority"

if [[ "${PREVIEW_DOTENVX_UPLOAD_REQUIRED:-false}" == "true" ]]; then
  [[ -s "$keys_file" || -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]] \
    || fail "dotenvx upload required but no local preview decryption material is available"
  [[ -f "$preview_file" ]] \
    || fail "dotenvx upload required but encrypted preview environment is missing"
  has_encrypted_assignment GEMINI_API_KEY \
    || fail "GEMINI_API_KEY is not encrypted in preview environment"
  has_encrypted_assignment WA_STAGE1B_CERT_SECRET \
    || fail "WA_STAGE1B_CERT_SECRET is not encrypted in preview environment"

  # Prove the exact local key/payload pair before publishing the private key.
  if ! bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
    cleanup_local_preview_materialization
    fail "local preview dotenvx authority cannot decrypt the generated payload"
  fi

  if upload_authority && verify_authority >/dev/null; then
    # The local key remains the exact key that was just uploaded. Re-run the
    # cryptographic proof locally; do not require a secret manager read-back.
    if bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
      echo "uploaded_dotenvx_keys_to_production"
      exit 0
    fi
  fi

  cleanup_local_preview_materialization
  fail "PREVIEW_DOTENVX_PRODUCTION_AUTHORITY_DEFERRED"
fi

if bash "$script_dir/verify-preview-dotenv-crypto-authority.sh" >/dev/null 2>&1; then
  echo "preview_dotenv_crypto_authority_verified"
  exit 0
fi

cleanup_local_preview_materialization
fail "preview dotenvx authority is not confirmed for the encrypted preview environment"
