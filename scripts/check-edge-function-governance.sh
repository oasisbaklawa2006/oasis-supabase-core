#!/usr/bin/env bash
# Edge-only PRs still trigger Migration CI static governance via scripts/** path filters.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config='supabase/config.toml'
[[ -f "$config" ]] || { echo 'EDGE GOVERNANCE VIOLATION: supabase/config.toml missing' >&2; exit 1; }

required_preview=(
  catalogue-ai-copy
  test-integration
  whatsapp-studio-inbox-bridge
)

for fn in "${required_preview[@]}"; do
  grep -Fxq "[functions.${fn}]" "$config" \
    || { echo "EDGE GOVERNANCE VIOLATION: approved function ${fn} is not declared" >&2; exit 1; }
done

grep -A1 -Fx '[functions.catalogue-ai-copy]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE GOVERNANCE VIOLATION: catalogue-ai-copy must verify JWT' >&2; exit 1; }
grep -A1 -Fx '[functions.test-integration]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE GOVERNANCE VIOLATION: test-integration must verify JWT' >&2; exit 1; }
grep -A1 -Fx '[functions.whatsapp-studio-inbox-bridge]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'EDGE GOVERNANCE VIOLATION: bridge custom-auth mode changed without review' >&2; exit 1; }

for prohibited in whatsapp-webhook generate-product-attributes; do
  if grep -Fxq "[functions.${prohibited}]" "$config"; then
    echo "EDGE GOVERNANCE VIOLATION: ${prohibited} cannot be preview auto-deployed" >&2
    exit 1
  fi
done

retired='supabase/functions/generate-product-attributes/index.ts'
[[ -f "$retired" ]] \
  || { echo 'EDGE GOVERNANCE VIOLATION: generate-product-attributes retirement tombstone missing' >&2; exit 1; }
grep -Fq 'status: 410' "$retired" \
  || { echo 'EDGE GOVERNANCE VIOLATION: retired product attribute endpoint must return 410' >&2; exit 1; }
grep -Fq 'retired: true' "$retired" \
  || { echo 'EDGE GOVERNANCE VIOLATION: retired product attribute endpoint marker missing' >&2; exit 1; }
if grep -Eiq 'hsn_code|gst_rate|shelf_life_days|allergen_warnings|nutritional_info' "$retired"; then
  echo 'EDGE GOVERNANCE VIOLATION: retired product attribute endpoint contains generated compliance attributes' >&2
  exit 1
fi

# Broad deployment commands can unintentionally overwrite provider callbacks.
if grep -RInE 'supabase functions deploy([[:space:]]|$)' .github scripts \
  --include='*.yml' --include='*.yaml' --include='*.sh' \
  | grep -Ev 'functions deploy [a-z0-9-]+'; then
  echo 'EDGE GOVERNANCE VIOLATION: broad Edge Function deployment command detected' >&2
  exit 1
fi

echo 'Edge Function governance check passed.'
