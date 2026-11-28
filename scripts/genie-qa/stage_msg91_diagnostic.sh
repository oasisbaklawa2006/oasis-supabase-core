#!/usr/bin/env bash
# Stage from the already certified real-provider source; change the OTP guard only.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$#" == 2 && "$1" == skhpmltfjgqitntkmclb && ! -e "$2" && ! -L "$2" ]] || exit 1
bash "$ROOT/scripts/genie-qa/stage_msg91_provider_candidate.sh" "$1" "$2"
cp "$ROOT/scripts/genie-qa/qa-msg91-provider-diagnostic-guard.mjs" "$2/supabase/functions/msg91-otp/qa-msg91-provider-guard.mjs"
python3 "$ROOT/scripts/edge-function-source-manifest.py" "$2/supabase/functions" msg91-otp --output "$2/diagnostic-source.json"
# Only OTP is staged for deployment; the bridge is not a deploy target.
rm -rf -- "$2/supabase/functions/msg91-session-bridge"
