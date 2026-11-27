#!/usr/bin/env bash
# Local source-only staging; this script cannot deploy or contact a provider.
set -euo pipefail
[[ "$#" == 2 && "$1" == skhpmltfjgqitntkmclb && ! -e "$2" && ! -L "$2" ]] || { echo 'QA_STAGE_TARGET_DENIED' >&2; exit 1; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
umask 077
mkdir -- "$2"
mkdir -p -- "$2/supabase/functions"
cp -a "$root/supabase/functions/msg91-otp" "$2/supabase/functions/"
cp -a "$root/supabase/functions/msg91-session-bridge" "$2/supabase/functions/"
cp -a "$root/supabase/functions/_shared" "$2/supabase/functions/"
otp="$2/supabase/functions/msg91-otp"
mv "$otp/provider-verify.mjs" "$otp/provider-verify-canonical.mjs"
cp "$root/scripts/genie-qa/qa-msg91-provider-guard.mjs" "$otp/"
cp "$root/scripts/genie-qa/qa-msg91-provider-overlay.mjs" "$otp/provider-verify.mjs"
# Only scratch entrypoints use the dedicated QA credential.
python3 - "$2/supabase/functions" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for slug in ("msg91-otp", "msg91-session-bridge"):
    entry = root / slug / "index.ts"
    original = entry.read_text(encoding="utf-8")
    old = 'Deno.env.get("MSG91_AUTH_KEY")'
    if original.count(old) != 1:
        raise SystemExit("QA credential binding changed: review required")
    entry.write_text(original.replace(old, 'Deno.env.get("QA_MSG91_PROVIDER_AUTH_KEY")'), encoding="utf-8")
PY
printf 'project_id = "skhpmltfjgqitntkmclb"\n' > "$2/supabase/config.toml"
for slug in msg91-otp msg91-session-bridge; do
  python3 "$root/scripts/edge-function-source-manifest.py" "$2/supabase/functions" "$slug" --output "$2/$slug-source.json"
done
echo 'QA_PROVIDER_CANDIDATE_STAGED_NO_DEPLOY'
