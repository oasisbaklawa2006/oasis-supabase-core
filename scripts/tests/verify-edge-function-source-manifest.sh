#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

first="$(mktemp)"
second="$(mktemp)"
trap 'rm -f "$first" "$second"' EXIT

python3 scripts/edge-function-source-manifest.py   supabase/functions whatsapp-webhook --output "$first"
python3 scripts/edge-function-source-manifest.py   supabase/functions whatsapp-webhook --output "$second"

cmp -s "$first" "$second"
jq -e '.function == "whatsapp-webhook"' "$first" >/dev/null
jq -e '.entrypoint == "whatsapp-webhook/index.ts"' "$first" >/dev/null
jq -e '.fileCount > 5' "$first" >/dev/null
jq -e '.closureSha256 | test("^[0-9a-f]{64}$")' "$first" >/dev/null
jq -e '.files | any(.path == "_shared/whatsappWebhookBoundary.ts")' "$first" >/dev/null
jq -e '.files | any(.path == "_shared/whatsappOperatorReplyStatus.ts")' "$first" >/dev/null

fixture_root="$(mktemp -d)"
trap 'rm -f "$first" "$second"; rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/functions/demo"
cat > "$fixture_root/functions/demo/index.ts" <<'TS'
import { hidden } from "@shared/hidden";
console.log(hidden);
TS

if python3 scripts/edge-function-source-manifest.py   "$fixture_root/functions" demo >/dev/null 2>&1; then
  echo "Expected hidden import-map alias to fail source attestation" >&2
  exit 1
fi

comment_fixture="$(mktemp -d)"
mkdir -p "$comment_fixture/functions/demo"
cat > "$comment_fixture/functions/demo/dependency.ts" <<'TS'
export const traced = 42;
TS
cat > "$comment_fixture/functions/demo/index.ts" <<'TS'
import { traced } from /* traced dependency */ "./dependency.ts";
console.log(traced);
TS

comment_manifest="$(mktemp)"
python3 scripts/edge-function-source-manifest.py   "$comment_fixture/functions" demo --output "$comment_manifest"
jq -e '.files | any(.path == "demo/dependency.ts")' "$comment_manifest" >/dev/null
rm -rf "$comment_fixture" "$comment_manifest"

fail_closed_fixture="$(mktemp -d)"
mkdir -p "$fail_closed_fixture/functions/demo"
cat > "$fail_closed_fixture/functions/demo/index.ts" <<'TS'
const note = "import { x } from './ignored.ts'";
export const ok = 1;
TS
python3 scripts/edge-function-source-manifest.py   "$fail_closed_fixture/functions" demo --output "$first"
jq -e '.fileCount == 1' "$first" >/dev/null
rm -rf "$fail_closed_fixture"

python3 - <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "edge_manifest",
    Path("scripts/edge-function-source-manifest.py"),
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

sample = 'import { value } from /* traced dependency */ "./dependency.ts";\n'
module.assert_fail_closed_import_scan(sample, Path("demo/index.ts"))

original = module.import_specifiers

def broken_import_scan(_source: str) -> list[str]:
    return []

module.import_specifiers = broken_import_scan
try:
    module.assert_fail_closed_import_scan(sample, Path("demo/index.ts"))
except SystemExit as exc:
    if "fail-closed import scan" not in str(exc):
        raise
else:
    print("Expected fail-closed import scan to reject unaccounted local import", file=sys.stderr)
    sys.exit(1)
finally:
    module.import_specifiers = original
PY

echo "Edge Function source manifest regression passed."
