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
sed -i 's/^  preflight:$/  preflight:\n    permissions: write-all/' "$fixture"
reject_mutation "inline write-all override on a non-deploy job"
sed -i 's/^  observe:$/  observe:\n    permissions:\n      contents: write/' "$fixture"
reject_mutation "block permission override on the observation job"
sed -i "s/github\.ref == 'refs\/heads\/main' && //" "$fixture"
reject_mutation "release jobs runnable from a non-main ref"
for job_if in "    if: github.ref == 'refs/heads/main' \&\& inputs.observe_only != true" \
  "    if: github.ref == 'refs/heads/main' \&\& github.event_name == 'workflow_dispatch' \&\& inputs.deploy == true" \
  "    if: github.ref == 'refs/heads/main' \&\& github.event_name == 'workflow_dispatch' \&\& inputs.observe_only == true"; do
  # Keep the original condition in a comment while the effective job-level condition becomes always().
  python3 - "$fixture" "$job_if" <<'PYEOF'
import sys
path, prefix = sys.argv[1], sys.argv[2].replace("\\&", "&")
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    if line.startswith(prefix):
        lines[i] = "    if: always()\n    # " + line.strip()
        break
else:
    raise SystemExit("job condition not found: " + prefix)
open(path, "w").write("\n".join(lines))
PYEOF
  reject_mutation "job-level condition replaced by always() with the original kept in a comment"
done
sed -i 's/ -q -t -A -v ON_ERROR_STOP=1/ -q -v ON_ERROR_STOP=1/' "$fixture"
reject_mutation "snapshot caller without bare-tuples flags"
cp "$tmpdir/workflow.orig" "$fixture"
sed -i '1a\\pset tuples_only on' "$tmpdir/scripts/sql/snapshot-whatsapp-packet-ai-consumer-production-state.sql"
if (cd "$tmpdir" && bash scripts/check-whatsapp-packet-ai-consumer-production-release.sh) >/dev/null 2>&1; then
  echo "FAIL: governance accepted a psql meta-command in the snapshot SQL" >&2
  exit 1
fi
sed -i "s/created >= now() - interval '3 hours'/created >= :'since'::timestamptz/" "$tmpdir/scripts/sql/observe-whatsapp-packet-ai-consumer-production-ticks.sql"
if (cd "$tmpdir" && bash scripts/check-whatsapp-packet-ai-consumer-production-release.sh) >/dev/null 2>&1; then
  echo "FAIL: governance accepted psql variable interpolation in the observation SQL" >&2
  exit 1
fi
echo "WhatsApp packet AI consumer production release governance regression passed."
