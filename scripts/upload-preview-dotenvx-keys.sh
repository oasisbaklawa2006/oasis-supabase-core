#!/usr/bin/env bash
# Ensure production holds dotenvx preview decryption authority for branching.
# Uploads fresh keys when newly generated; otherwise verifies existing authority.
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

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  if [[ -f "$preview_file" ]] && grep -Fq 'encrypted:' "$preview_file"; then
    echo "preview_dotenvx_provisioned_via_github_secret"
    exit 0
  fi
fi

if [[ "${PREVIEW_DOTENVX_UPLOAD_REQUIRED:-false}" == "true" ]]; then
  [[ -f "$keys_file" || -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]] \
    || fail "dotenvx upload required but no local preview decryption material is available"
  if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    if upload_authority && verify_authority; then
      echo "uploaded_dotenvx_keys_to_production"
      exit 0
    fi
    cleanup_local_preview_materialization
    echo "preview_dotenvx_production_authority_deferred"
    exit 0
  fi
  cleanup_local_preview_materialization
  echo "preview_dotenvx_production_authority_deferred"
  exit 0
fi

if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  if verify_authority 2>/dev/null; then
    echo "production_dotenvx_preview_authority_present"
    exit 0
  fi
fi

if [[ -f "$preview_file" ]] && grep -Fq 'encrypted:' "$preview_file"; then
  cleanup_local_preview_materialization
  echo "preview_dotenvx_production_authority_deferred"
  exit 0
fi

fail "preview dotenvx authority unavailable and no encrypted preview env is provisioned"
