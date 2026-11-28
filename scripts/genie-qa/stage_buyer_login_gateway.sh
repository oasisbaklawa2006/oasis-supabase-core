#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$#" == 2 && "$1" == skhpmltfjgqitntkmclb && ! -e "$2" && ! -L "$2" ]] || exit 1
snapshot="$ROOT/scripts/genie-qa/central-buyer-login-gateway.snapshot.txt"
[[ "$(git hash-object "$snapshot")" == 2f1ff3124137910716d790977ba8fc7e88dba85d ]] || exit 1
mkdir -- "$2"
mkdir -p "$2/supabase/functions/buyer-login-gateway"
printf 'project_id = "skhpmltfjgqitntkmclb"\n' > "$2/supabase/config.toml"
python3 - "$snapshot" "$2/supabase/functions/buyer-login-gateway/index.ts" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
marker = '    if (body.mode !== "preflight" || !channel || !identifier.trim())'
if source.count(marker) != 1:
    raise SystemExit("gateway source marker mismatch")
source = 'import { allowQaBuyerPreflight } from "./qa-gateway-guard.mjs";\n' + source.replace(
    marker,
    '    if (!allowQaBuyerPreflight((name: string) => Deno.env.get(name), body)) return json({ ok: true, ...result("ambiguous", "mobile") });\n' + marker,
)
# The original snapshot stays byte-exact for provenance. Remove the email-only
# functions and dispatch branch from the QA bundle rather than retaining an
# unreachable wildcard-email lookup.
for start, end in [
    ("function normalizeEmail(", "function normalizePhone("),
    ("async function classifyEmail(", "async function classifyMobile("),
]:
    if source.count(start) != 1 or source.count(end) != 1:
        raise SystemExit("gateway mobile-only staging marker mismatch")
    first, last = source.index(start), source.index(end)
    if first >= last:
        raise SystemExit("gateway mobile-only staging order mismatch")
    source = source[:first] + source[last:]
dispatch = '    const eligibility = channel === "email"\n      ? await classifyEmail(identifier)\n      : await classifyMobile(identifier);'
if source.count(dispatch) != 1:
    raise SystemExit("gateway dispatch marker mismatch")
source = source.replace(dispatch, '    const eligibility = await classifyMobile(identifier);')
Path(sys.argv[2]).write_text(source)
PY
cp "$ROOT/scripts/genie-qa/qa-gateway-guard.mjs" "$2/supabase/functions/buyer-login-gateway/"
python3 "$ROOT/scripts/edge-function-source-manifest.py" "$2/supabase/functions" buyer-login-gateway --output "$2/gateway-source.json"
