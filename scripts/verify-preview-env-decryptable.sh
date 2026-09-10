#!/usr/bin/env bash
# Verify supabase/.env.preview decrypts with the local dotenvx authority used
# for this exact-head materialization. Production authority is verified
# separately by secret name; production secret values are never read back.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
dotenvx_version="1.44.1"

[[ -f "$preview_file" ]] || exit 1
grep -Eq '^GEMINI_API_KEY="?encrypted:' "$preview_file" || exit 1
grep -Eq '^WA_STAGE1B_CERT_SECRET="?encrypted:' "$preview_file" || exit 1

# An explicitly supplied repository key is materialized into the local key file.
# Otherwise require the key file generated/loaded in this same job. Do not try to
# read a production secret value back from Supabase: production authority is
# proven independently by verify-production-dotenvx-authority.sh.
if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  umask 077
  mkdir -p supabase
  printf 'DOTENV_PRIVATE_KEY_PREVIEW=%s\n' "$PREVIEW_DOTENV_PRIVATE_KEY" > "$keys_file"
  echo "::add-mask::${PREVIEW_DOTENV_PRIVATE_KEY}" >&2
fi

[[ -s "$keys_file" ]] || exit 1

npx --yes "@dotenvx/dotenvx@${dotenvx_version}" get GEMINI_API_KEY \
  -f "$preview_file" -fk "$keys_file" --stdout >/dev/null 2>&1
npx --yes "@dotenvx/dotenvx@${dotenvx_version}" get WA_STAGE1B_CERT_SECRET \
  -f "$preview_file" -fk "$keys_file" --stdout >/dev/null 2>&1
