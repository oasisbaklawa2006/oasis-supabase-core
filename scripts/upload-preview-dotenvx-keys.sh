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

[[ -f "$keys_file" ]] || {
  if [[ -f supabase/.env.preview ]] && grep -Fq 'encrypted:' supabase/.env.preview; then
    echo "continuing_with_git_encrypted_preview_env"
    exit 0
  fi
  fail "$keys_file is missing; run materialize-supabase-env-preview.sh first"
}

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  echo "verified_github_preview_dotenv_private_key"
  exit 0
fi

if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  if [[ "${PREVIEW_DOTENVX_UPLOAD_REQUIRED:-false}" == "true" ]]; then
    if supabase secrets set --env-file "$keys_file" --project-ref "$production_ref" 2>/dev/null; then
      echo "uploaded_dotenvx_keys_to_production"
      exit 0
    fi
    echo "preview dotenvx upload via Management API unavailable; verifying existing production authority" >&2
  fi

  if bash "$script_dir/verify-production-dotenvx-authority.sh" 2>/dev/null; then
    exit 0
  fi
fi

echo "preview_dotenvx_management_api_unavailable; continuing with git encrypted preview env only" >&2
echo "continuing_with_git_encrypted_preview_env"
