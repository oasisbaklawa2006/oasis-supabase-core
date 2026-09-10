#!/usr/bin/env bash
# Upload dotenvx decryption keys to the production Supabase project so the
# branching executor can decrypt supabase/.env.preview on ephemeral previews.
# Never targets preview project refs and never prints secret values.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

keys_file="supabase/.env.keys"
production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"

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

supabase secrets set --env-file "$keys_file" --project-ref "$production_ref"
echo "uploaded_dotenvx_keys_to_production"
