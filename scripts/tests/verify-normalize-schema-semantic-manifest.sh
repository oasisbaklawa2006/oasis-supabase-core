#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

write_manifest() {
  local path="$1"
  cat >"$path" <<'ROWS'
{"kind":"storage_relation_grant","key":"storage.buckets:anon:SELECT","value":{"grantable":false}}
{"kind":"storage_relation_grant","key":"storage.buckets:anon:MAINTAIN","value":{"grantable":false}}
{"kind":"storage_relation_grant","key":"storage.objects:authenticated:TRUNCATE","value":{"grantable":false}}
ROWS
}

write_manifest "$tmpdir/local.manifest"
write_manifest "$tmpdir/remote.manifest"
# Remote lacks the non-portable privilege rows; both sides should normalize identically.
grep -v MAINTAIN "$tmpdir/remote.manifest" | grep -v TRUNCATE >"$tmpdir/remote-trimmed.manifest"
mv "$tmpdir/remote-trimmed.manifest" "$tmpdir/remote.manifest"

python3 scripts/normalize-schema-semantic-manifest.py \
  "$tmpdir/local.manifest" "$tmpdir/remote.manifest"

diff -q "$tmpdir/local.manifest" "$tmpdir/remote.manifest" >/dev/null

echo "normalize-schema-semantic-manifest storage grant canonicalization passed."
