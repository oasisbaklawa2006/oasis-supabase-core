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

[[ -f "$keys_file" ]] || fail "$keys_file is missing; run materialize-supabase-env-preview.sh first"
[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || fail "SUPABASE_ACCESS_TOKEN is required"
[[ "$production_ref" =~ ^[a-z0-9]{20}$ ]] || fail "invalid production project ref"

if [[ -n "${PREVIEW_REF:-}" && "$PREVIEW_REF" == "$production_ref" ]]; then
  fail "production ref must not be supplied as PREVIEW_REF"
fi

if [[ "${PREVIEW_DOTENVX_UPLOAD_REQUIRED:-false}" == "true" ]]; then
  if supabase secrets set --env-file "$keys_file" --project-ref "$production_ref"; then
    echo "uploaded_dotenvx_keys_to_production"
    exit 0
  fi
  echo "preview dotenvx upload via Management API unavailable; verifying existing production authority" >&2
fi

bash "$script_dir/verify-production-dotenvx-authority.sh"
echo "verified_production_dotenvx_preview_authority"
