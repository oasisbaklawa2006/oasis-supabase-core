#!/usr/bin/env bash
# Installs the integrity-locked Supabase CLI for one pinned version and puts it on PATH.
set -euo pipefail

version="${1:?usage: install-locked-supabase-cli.sh <version>}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/supabase-cli/${version}"

test -f "$dir/package-lock.json" || { echo "No locked Supabase CLI for version ${version}" >&2; exit 1; }
grep -q "\"supabase\": \"${version}\"" "$dir/package.json" || { echo "package.json does not pin ${version}" >&2; exit 1; }

npm ci --ignore-scripts --no-audit --no-fund --prefix "$dir"

bin="$dir/node_modules/.bin"
test "$("$bin/supabase" --version)" = "$version"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin" >> "$GITHUB_PATH"
fi
echo "Installed Supabase CLI ${version} from lockfile"
