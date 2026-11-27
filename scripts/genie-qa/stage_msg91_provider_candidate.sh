#!/usr/bin/env bash
# Local source-only staging; this script cannot deploy or contact a provider.
set -euo pipefail
[[ "$#" == 2 && "$1" == skhpmltfjgqitntkmclb && ! -e "$2" ]] || { echo 'QA_STAGE_TARGET_DENIED' >&2; exit 1; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$2/supabase/functions"
cp -a "$root/supabase/functions/msg91-otp" "$2/supabase/functions/"
cp -a "$root/supabase/functions/msg91-session-bridge" "$2/supabase/functions/"
cp -a "$root/supabase/functions/_shared" "$2/supabase/functions/"
otp="$2/supabase/functions/msg91-otp"
mv "$otp/provider-verify.mjs" "$otp/provider-verify-canonical.mjs"
cp "$root/scripts/genie-qa/qa-msg91-provider-guard.mjs" "$otp/"
cp "$root/scripts/genie-qa/qa-msg91-provider-overlay.mjs" "$otp/provider-verify.mjs"
printf 'project_id = "skhpmltfjgqitntkmclb"\n' > "$2/supabase/config.toml"
for slug in msg91-otp msg91-session-bridge; do
  python3 "$root/scripts/edge-function-source-manifest.py" "$2/supabase/functions" "$slug" --output "$2/$slug-source.json"
done
echo 'QA_PROVIDER_CANDIDATE_STAGED_NO_DEPLOY'
