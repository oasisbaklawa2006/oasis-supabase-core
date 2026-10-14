#!/usr/bin/env bash
# Report whether LOCAL dotenvx decryption material is already present.
#
# This script deliberately never contacts Supabase. The Management API secrets
# endpoint does not return stored secret values, so nothing read back from it
# can be a private key; using such a value as a key authority produces
# self-referential "proofs" that pass in CI while the hosted executor fails.
# Independent key custody (a protected GitHub secret) is the only supported
# source. Output contract (consumed by materialize-supabase-env-preview.sh):
#   loaded_existing_local_dotenvx_keys | no_production_dotenvx_private_key
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

keys_file="supabase/.env.keys"

if [[ -s "$keys_file" ]]; then
  echo "loaded_existing_local_dotenvx_keys"
  exit 0
fi

echo "no_production_dotenvx_private_key"
