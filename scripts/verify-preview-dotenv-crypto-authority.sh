#!/usr/bin/env bash
# Cryptographically prove supabase/.env.preview matches available decryption authority.
# Secret names on production are never sufficient on their own.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

script_dir="$(dirname "$0")"
preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"

[[ -f "$preview_file" ]] || exit 1

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  bash "$script_dir/verify-preview-env-decryptable.sh"
  exit 0
fi

if [[ -s "$keys_file" ]]; then
  bash "$script_dir/verify-preview-env-decryptable.sh"
  exit 0
fi

if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  key_state="$(bash "$script_dir/load-preview-dotenvx-keys.sh")"
  case "$key_state" in
    loaded_existing_local_dotenvx_keys|loaded_production_dotenvx_private_key)
      bash "$script_dir/verify-preview-env-decryptable.sh"
      exit 0
      ;;
  esac
fi

exit 1
