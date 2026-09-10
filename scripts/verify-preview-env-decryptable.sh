#!/usr/bin/env bash
# Verify supabase/.env.preview decrypts with available preview dotenvx authority.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
script_dir="$(dirname "$0")"
dotenvx_version="1.44.1"
production_ref="${PRODUCTION_PROJECT_REF:-tcxvcatsqqertcnycuop}"

[[ -f "$preview_file" ]] || exit 1
grep -Fq "encrypted:" "$preview_file" || exit 1

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  umask 077
  mkdir -p supabase
  printf 'DOTENV_PRIVATE_KEY_PREVIEW=%s\n' "$PREVIEW_DOTENV_PRIVATE_KEY" > "$keys_file"
fi

if [[ ! -s "$keys_file" && -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  bash "$script_dir/load-preview-dotenvx-keys.sh" >/dev/null 2>&1 || true
fi

[[ -s "$keys_file" ]] || exit 1

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" get GEMINI_API_KEY \
  -f "$preview_file" --stdout >/dev/null 2>&1
