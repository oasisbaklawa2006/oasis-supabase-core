#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

cleanup_paths=()
register_cleanup() {
  cleanup_paths+=("$1")
}

cleanup() {
  local path
  for path in "${cleanup_paths[@]}"; do
    if [[ -d "$path" ]]; then
      rm -rf "$path"
    elif [[ -e "$path" ]]; then
      rm -f "$path"
    fi
  done
}
trap cleanup EXIT

first="$(mktemp)"
register_cleanup "$first"
second="$(mktemp)"
register_cleanup "$second"

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
register_cleanup "$fixture_root"
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
register_cleanup "$comment_fixture"
mkdir -p "$comment_fixture/functions/demo"
cat > "$comment_fixture/functions/demo/dependency.ts" <<'TS'
export const traced = 42;
TS
cat > "$comment_fixture/functions/demo/index.ts" <<'TS'
import { traced } from /* traced dependency */ "./dependency.ts";
console.log(traced);
TS

comment_manifest="$(mktemp)"
register_cleanup "$comment_manifest"
python3 scripts/edge-function-source-manifest.py   "$comment_fixture/functions" demo --output "$comment_manifest"
jq -e '.files | any(.path == "demo/dependency.ts")' "$comment_manifest" >/dev/null

multiline_fixture="$(mktemp -d)"
register_cleanup "$multiline_fixture"
mkdir -p "$multiline_fixture/functions/demo"
cat > "$multiline_fixture/functions/demo/dependency.ts" <<'TS'
export const helper = "ok";
TS
cat > "$multiline_fixture/functions/demo/index.ts" <<'TS'
import {
  helper,
} from
  /* traced dependency */
  "./dependency.ts";
console.log(helper);
TS

multiline_manifest="$(mktemp)"
register_cleanup "$multiline_manifest"
python3 scripts/edge-function-source-manifest.py   "$multiline_fixture/functions" demo --output "$multiline_manifest"
jq -e '.files | any(.path == "demo/dependency.ts")' "$multiline_manifest" >/dev/null

semicolon_free_fixture="$(mktemp -d)"
register_cleanup "$semicolon_free_fixture"
mkdir -p "$semicolon_free_fixture/functions/demo"
cat > "$semicolon_free_fixture/functions/demo/a.ts" <<'TS'
export const a = 1;
TS
cat > "$semicolon_free_fixture/functions/demo/side-effect.ts" <<'TS'
export const side = 2;
TS
cat > "$semicolon_free_fixture/functions/demo/index.ts" <<'TS'
import { a } from "./a.ts"
import "./side-effect.ts"
import {
  a as renamed,
} from
  "./a.ts"
TS

semicolon_free_manifest="$(mktemp)"
register_cleanup "$semicolon_free_manifest"
python3 scripts/edge-function-source-manifest.py   "$semicolon_free_fixture/functions" demo --output "$semicolon_free_manifest"
jq -e '.files | any(.path == "demo/a.ts")' "$semicolon_free_manifest" >/dev/null
jq -e '.files | any(.path == "demo/side-effect.ts")' "$semicolon_free_manifest" >/dev/null

fail_closed_fixture="$(mktemp -d)"
register_cleanup "$fail_closed_fixture"
mkdir -p "$fail_closed_fixture/functions/demo"
cat > "$fail_closed_fixture/functions/demo/index.ts" <<'TS'
const note = "import { x } from './ignored.ts'";
export const ok = 1;
TS
python3 scripts/edge-function-source-manifest.py   "$fail_closed_fixture/functions" demo --output "$first"
jq -e '.fileCount == 1' "$first" >/dev/null

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
multiline_sample = (
    'import {\n'
    '  helper,\n'
    '} from\n'
    '  /* traced dependency */\n'
    '  "./dependency.ts";\n'
)
semicolon_free_sample = (
    'import { a } from "./a.ts"\n'
    'import "./side-effect.ts"\n'
)
module.assert_fail_closed_import_scan(sample, Path("demo/index.ts"))
module.assert_fail_closed_import_scan(multiline_sample, Path("demo/index.ts"))
discovered = module.discover_import_specifiers(
    module.strip_js_comments(semicolon_free_sample)
)
if set(discovered) != {"./a.ts", "./side-effect.ts"}:
    raise SystemExit(f"unexpected semicolon-free discovery: {discovered!r}")

original = module.import_specifiers

def broken_import_scan(_source: str) -> list[str]:
    return []

module.import_specifiers = broken_import_scan
try:
    module.assert_fail_closed_import_scan(multiline_sample, Path("demo/index.ts"))
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
