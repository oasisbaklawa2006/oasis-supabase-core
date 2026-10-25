#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bash scripts/check-whatsapp-packet-ai-consumer-production-release.sh

# Exercise the validator against isolated mutations of the real workflow: each
# unsafe change must be rejected by the governance check.
workflow=".github/workflows/whatsapp-packet-ai-consumer-production-release.yml"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
git ls-files -z -- . ':!.github/supabase-cli' | tar --null -T - -cf - | tar -xf - -C "$tmpdir"
for untracked in $(git ls-files --others --exclude-standard); do
  mkdir -p "$tmpdir/$(dirname "$untracked")"
  cp "$untracked" "$tmpdir/$untracked"
done
fixture="$tmpdir/$workflow"
cp "$workflow" "$tmpdir/workflow.orig"

reject_mutation() {
  local label="$1"
  if (cd "$tmpdir" && git init -q . 2>/dev/null; cd "$tmpdir" && bash scripts/check-whatsapp-packet-ai-consumer-production-release.sh) >/dev/null 2>&1; then
    echo "FAIL: governance accepted an unsafe consumer release workflow: $label" >&2
    exit 1
  fi
  cp "$tmpdir/workflow.orig" "$fixture"
}

sed -i 's/^    environment: supabase-production$/    environment: supabase-production-readonly/' "$fixture"
reject_mutation "deploy without the protected production approval environment"
sed -i 's/\.verify_jwt == false/.verify_jwt == true/g' "$fixture"
reject_mutation "wrong verify_jwt assertion"
sed -i 's/ --no-verify-jwt//; s/--no-verify-jwt//' "$fixture"
reject_mutation "deploy without the explicit gateway JWT setting"
sed -i 's/^  workflow_dispatch:$/  push:\n    branches: [main]\n  workflow_dispatch:/' "$fixture"
reject_mutation "automatic production trigger"
sed -i 's/supabase functions deploy whatsapp-packet-ai-consumer/supabase functions deploy/' "$fixture"
reject_mutation "broad Edge deployment"
sed -i 's/^      id-token: write$/      id-token: write\n      contents: write/' "$fixture"
reject_mutation "extra token scope"
sed -i 's/EXPECTED_LIVE_BUNDLE_SHA: [0-9a-f]*/EXPECTED_LIVE_BUNDLE_SHA: 0000000000000000000000000000000000000000000000000000000000000000/' "$fixture"
reject_mutation "wrong live bundle baseline"
sed -i 's/REQUIRED_HEALTHY_TICKS: "15"/REQUIRED_HEALTHY_TICKS: "1"/' "$fixture"
reject_mutation "weakened observation requirement"
sed -i 's/test "\$wrong_code" = "403"/true/' "$fixture"
reject_mutation "removed wrong-secret smoke"
sed -i 's/git merge-base --is-ancestor "\$RELEASE_SHA_INPUT" origin\/main/true/' "$fixture"
reject_mutation "release not bound to protected main"
sed -i 's/^    needs: preflight$/    needs: []/' "$fixture"
reject_mutation "deploy decoupled from preflight"
echo "WhatsApp packet AI consumer production release governance regression passed."
