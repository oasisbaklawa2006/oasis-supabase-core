#!/usr/bin/env bash
# Build a verified rollback tarball + manifest for a live Edge Function download tree.
#
# Fail closed: the recursive local import closure of the entrypoint must resolve
# completely, the archive must contain exactly the manifest files, and every file
# hash must verify after the archive is extracted again. There is no weaker mode;
# a closure is never replaced by the live bundle hash.
#
# `supabase functions download --use-api` omits modules the bundler erased, such as
# `import type` dependencies. The only way to complete such an omission is an
# explicit pinned completion record (see edge-function-rollback-completion.py),
# which is recorded in the manifest as historical git material, not live evidence.
set -euo pipefail

usage() {
  echo "usage: $0 <functions_root> <function_name> <live_metadata.json> <manifest_out> <tarball_out> [completion_pin.json]" >&2
}

if [[ $# -lt 5 || $# -gt 6 ]]; then
  usage
  exit 2
fi

functions_root="$1"
function_name="$2"
live_metadata_json="$3"
manifest_out="$4"
tarball_out="$5"
completion_pin="${6:-}"

cd "$(git rev-parse --show-toplevel)"
repo_root="$PWD"

test -d "$functions_root/$function_name"
test -f "$live_metadata_json"
if [[ -n "$completion_pin" ]]; then
  test -f "$completion_pin"
fi

bundle_sha="$(jq -er '.ezbr_sha256' "$live_metadata_json")"
[[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]]
live_version="$(jq -er '.version' "$live_metadata_json")"
[[ "$live_version" =~ ^[0-9]+$ ]]

# A failed run must never leave a previous capture behind to be mistaken for this one.
rm -f "$manifest_out" "$tarball_out"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/functions"
cp -a "$functions_root/." "$work/functions/"

origins="$work/origins.json"
if [[ -n "$completion_pin" ]]; then
  python3 scripts/edge-function-rollback-completion.py complete \
    --functions-root "$work/functions" \
    --pin "$completion_pin" \
    --live-metadata "$live_metadata_json" \
    --repo-root "$repo_root" \
    --origins-out "$origins"
else
  python3 - "$work/functions" "$origins" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
origins = {p.relative_to(root).as_posix(): {"origin": "live_api_download"}
           for p in sorted(root.rglob("*")) if p.is_file()}
Path(sys.argv[2]).write_text(json.dumps({"completed": [], "origins": origins}))
PY
fi

# Fails closed on any unresolved local import, unsupported specifier or escaped path.
python3 scripts/edge-function-source-manifest.py \
  "$work/functions" "$function_name" \
  --output "$work/closure.json"

jq -e \
  --arg fn "$function_name" \
  '.function == $fn and (.closureSha256 | test("^[0-9a-f]{64}$")) and .fileCount > 0' \
  "$work/closure.json" >/dev/null

jq -n \
  --slurpfile closure "$work/closure.json" \
  --slurpfile origins "$origins" \
  --arg bundle "$bundle_sha" \
  --argjson version "$live_version" \
  --arg pin "${completion_pin:-}" \
  '$closure[0] as $c | $origins[0] as $o
   | $c + {
       captureMode: (if ($o.completed | length) > 0
                     then "live_download_with_pinned_historical_completion"
                     else "live_download_closure" end),
       bundleSha256: $bundle,
       liveVersion: $version,
       completionPin: (if $pin == "" then null else $pin end),
       completedPaths: $o.completed,
       files: [$c.files[] | . + {origin: $o.origins[.path]}]
     }' >"$work/manifest.json"

tar -C "$work" -czf "$work/archive.tar.gz" functions
test -s "$work/archive.tar.gz"

python3 scripts/edge-function-rollback-completion.py verify-archive \
  --tarball "$work/archive.tar.gz" \
  --manifest "$work/manifest.json"

mkdir -p "$(dirname "$manifest_out")" "$(dirname "$tarball_out")"
mv "$work/manifest.json" "$manifest_out"
mv "$work/archive.tar.gz" "$tarball_out"
