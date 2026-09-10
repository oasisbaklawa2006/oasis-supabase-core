#!/usr/bin/env bash
# Ensure production holds dotenvx preview decryption authority for branching.
# Uploads fresh keys when newly generated; otherwise verifies existing authority.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

keys_file="supabase/.env.keys"
production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"
script_dir="$(dirname "$0")"

fail() {
  echo "UPLOAD PREVIEW DOTENVX KEYS FAILED: $*" >&2
  exit 1
}

verify_authority() {
  bash "$script_dir/verify-production-dotenvx-authority.sh"
}

upload_authority() {
  if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" || -s "$keys_file" ]]; then
    PRODUCTION_PROJECT_REF="$production_ref" \
      SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-}" \
      PREVIEW_DOTENV_PRIVATE_KEY="${PREVIEW_DOTENV_PRIVATE_KEY:-}" \
      DOTENV_KEYS_FILE="$keys_file" \
      python3 "$script_dir/upload-production-dotenvx-key.py"
    return 0
  fi
  return 1
}

if [[ "${PREVIEW_DOTENVX_UPLOAD_REQUIRED:-false}" == "true" ]]; then
  [[ -f "$keys_file" || -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]] \
    || fail "dotenvx upload required but no local preview decryption material is available"
  if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    upload_authority || fail "failed to upload DOTENV_PRIVATE_KEY_PREVIEW to production"
    verify_authority || fail "production dotenvx preview authority missing after upload"
    echo "uploaded_dotenvx_keys_to_production"
    exit 0
  fi
  fail "SUPABASE_ACCESS_TOKEN is required to upload preview dotenvx authority"
fi

if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  if verify_authority 2>/dev/null; then
    echo "production_dotenvx_preview_authority_present"
    exit 0
  fi
fi

if [[ -f supabase/.env.preview ]] && grep -Fq 'encrypted:' supabase/.env.preview; then
  fail "encrypted supabase/.env.preview exists but production dotenvx preview authority is unavailable"
fi

fail "preview dotenvx authority unavailable and no encrypted preview env is provisioned"
