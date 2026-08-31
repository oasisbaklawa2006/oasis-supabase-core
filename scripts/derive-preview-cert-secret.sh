#!/usr/bin/env bash
# Derive preview cert bearer token from confidential CI inputs (never logged).
set -euo pipefail

derive_preview_cert_secret() {
  local preview_ref="${1:?preview ref required}"
  local gemini_key="${2:?GEMINI_API_KEY required}"
  local repository="${3:-${GITHUB_REPOSITORY:-oasisbaklawa2006/oasis-supabase-core}}"
  python3 - <<'PY' "$repository" "$preview_ref" "$gemini_key"
import hashlib, sys
repo, preview, gemini = sys.argv[1:4]
print(hashlib.sha256(f"{repo}:{preview}:{gemini}".encode()).hexdigest())
PY
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  derive_preview_cert_secret "${1:?}" "${2:?}" "${3:-${GITHUB_REPOSITORY:-}}"
fi
