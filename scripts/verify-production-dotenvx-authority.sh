#!/usr/bin/env bash
# Verify production holds dotenvx preview decryption authority by secret name.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"

fail() {
  echo "PREVIEW DOTENVX AUTHORITY UNAVAILABLE: $*" >&2
  exit 1
}

[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || fail "SUPABASE_ACCESS_TOKEN is required"

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  echo "verified_github_preview_dotenv_private_key"
  exit 0
fi

names="$(supabase secrets list --project-ref "$production_ref" 2>/dev/null | awk -F '|' '
  NF >= 2 {
    name=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    if (name ~ /^[A-Za-z][A-Za-z0-9_]*$/) print name
  }')" || fail "production secrets list unavailable"

grep -Fxq "DOTENV_PRIVATE_KEY_PREVIEW" <<<"$names" \
  || fail "DOTENV_PRIVATE_KEY_PREVIEW is not provisioned on production"

echo "production_dotenvx_preview_authority_present"
