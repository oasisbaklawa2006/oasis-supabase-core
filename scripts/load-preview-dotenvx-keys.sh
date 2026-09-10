#!/usr/bin/env bash
# Load production-scoped dotenvx decryption material when readable, or fail closed.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

keys_file="supabase/.env.keys"
production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"
script_dir="$(dirname "$0")"

fail() {
  echo "PREVIEW DOTENVX KEY LOAD FAILED: $*" >&2
  exit 1
}

[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || fail "SUPABASE_ACCESS_TOKEN is required"

if [[ -s "$keys_file" ]]; then
  echo "loaded_existing_local_dotenvx_keys"
  exit 0
fi

names="$(supabase secrets list --project-ref "$production_ref" 2>/dev/null | awk -F '|' '
  NF >= 2 {
    name=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    if (name ~ /^[A-Za-z][A-Za-z0-9_]*$/) print name
  }')" || {
  echo "no_production_dotenvx_private_key"
  exit 0
}

if grep -Fxq "DOTENV_PRIVATE_KEY_PREVIEW" <<<"$names"; then
  if resolved="$(PRODUCTION_PROJECT_REF="$production_ref" SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" \
    python3 "$script_dir/fetch-production-dotenv-private-key.py" 2>/dev/null || true)" && [[ -n "$resolved" ]]; then
    umask 077
    mkdir -p supabase
    printf 'DOTENV_PRIVATE_KEY_PREVIEW="%s"\n' "$resolved" > "$keys_file"
    echo "::add-mask::$resolved"
    echo "loaded_production_dotenvx_private_key"
    exit 0
  fi
  fail "DOTENV_PRIVATE_KEY_PREVIEW exists on production but is not readable to refresh encrypted preview env"
fi

echo "no_production_dotenvx_private_key"
