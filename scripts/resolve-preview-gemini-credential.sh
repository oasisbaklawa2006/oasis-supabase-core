#!/usr/bin/env bash
# Resolve GEMINI_API_KEY for preview sync without logging values.
# Prefers explicit env vars; falls back to production Supabase secrets store.
set -euo pipefail

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  echo "gemini_source=github_env"
  exit 0
fi

if [[ -n "${GEMINI_API_KEY_PRIMARY:-}" ]]; then
  echo "::add-mask::${GEMINI_API_KEY_PRIMARY}"
  echo "GEMINI_API_KEY=${GEMINI_API_KEY_PRIMARY}" >> "${GITHUB_ENV:?}"
  echo "gemini_source=github_secret"
  exit 0
fi

if [[ -n "${GEMINI_API_KEY_FALLBACK:-}" ]]; then
  echo "::add-mask::${GEMINI_API_KEY_FALLBACK}"
  echo "GEMINI_API_KEY=${GEMINI_API_KEY_FALLBACK}" >> "${GITHUB_ENV:?}"
  echo "gemini_source=github_secret_fallback"
  exit 0
fi

test -n "${SUPABASE_ACCESS_TOKEN:-}" || {
  echo "Missing SUPABASE_ACCESS_TOKEN" >&2
  exit 1
}
test -n "${PRODUCTION_PROJECT_REF:-}" || {
  echo "Missing PRODUCTION_PROJECT_REF" >&2
  exit 1
}

prod_names="$(supabase secrets list --project-ref "$PRODUCTION_PROJECT_REF" | awk -F '|' '
  NF >= 2 {
    name=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    if (name ~ /^[A-Za-z][A-Za-z0-9_]*$/) print name
  }')"

grep -Fxq "GEMINI_API_KEY" <<<"$prod_names" || {
  echo "Production Supabase project lacks GEMINI_API_KEY secret name" >&2
  exit 1
}

resolved="$(python3 "$(dirname "$0")/resolve-production-gemini-secret.py")"
test -n "$resolved" || {
  echo "Unable to resolve GEMINI_API_KEY from production Supabase secrets store" >&2
  exit 1
}

echo "::add-mask::$resolved"
echo "GEMINI_API_KEY=$resolved" >> "${GITHUB_ENV:?}"
echo "gemini_source=production_supabase_secret"
