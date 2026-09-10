#!/usr/bin/env bash
# Verify production holds dotenvx preview decryption authority by secret name.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"
script_dir="$(dirname "$0")"

fail() {
  echo "PREVIEW DOTENVX AUTHORITY UNAVAILABLE: $*" >&2
  exit 1
}

[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || fail "SUPABASE_ACCESS_TOKEN is required"

if PRODUCTION_PROJECT_REF="$production_ref" \
  SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" \
  python3 "$script_dir/list-production-secret-names.py" \
  | grep -Fxq "DOTENV_PRIVATE_KEY_PREVIEW"; then
  echo "production_dotenvx_preview_authority_present"
  exit 0
fi

fail "DOTENV_PRIVATE_KEY_PREVIEW is not provisioned on production"
