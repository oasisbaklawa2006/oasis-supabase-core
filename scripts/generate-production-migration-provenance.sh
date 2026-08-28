#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

before_list="${1:-production-migration-list-before.txt}"
after_list="${2:-production-migration-list-after.txt}"
apply_log="${3:-production-db-push-result.txt}"
out_json="${4:-production-migration-provenance.json}"
out_applied="${5:-production-migration-applied-versions.json}"
migrations_dir="${MIGRATIONS_DIR:-supabase/migrations}"

fail() {
  echo "PRODUCTION MIGRATION PROVENANCE FAILED: $*" >&2
  exit 1
}

for file in "$before_list" "$after_list" "$apply_log"; do
  [[ -f "$file" ]] || fail "required evidence file is missing: $file"
done

extract_remote_versions() {
  local file="$1"
  # `supabase migration list` renders rows as `Local | Remote | Time` and may
  # decorate versions with backticks/ANSI. The REMOTE column is the authority
  # for what was actually present in production; using the first column would
  # incorrectly treat pending local migrations as already deployed.
  awk -F '\\|' '
    NF >= 2 {
      v=$2
      gsub(/[^0-9]/, "", v)
      if (v ~ /^[0-9]{14}$/) print v
    }
  ' "$file" | sort -u
}

extract_applied_log_versions() {
  local file="$1"
  grep -E 'Applying migration [0-9]{14}_.+\.sql' "$file" 2>/dev/null \
    | sed -E 's/.*Applying migration ([0-9]{14})_.*/\1/' \
    | sort -u || true
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

extract_remote_versions "$before_list" > "$tmp_dir/before.remote"
extract_remote_versions "$after_list" > "$tmp_dir/after.remote"
extract_applied_log_versions "$apply_log" > "$tmp_dir/apply.log"
comm -13 "$tmp_dir/before.remote" "$tmp_dir/after.remote" > "$tmp_dir/delta.remote"

previous_max="$(tail -n1 "$tmp_dir/before.remote" || true)"
new_max="$(tail -n1 "$tmp_dir/after.remote" || true)"

# The database-side delta and the CLI's explicit "Applying migration" evidence
# must agree exactly. This prevents a normal-looking success artifact from ever
# claiming "applied nothing" after a real deployment, and also detects partial
# or externally-mutated ledgers.
if ! diff -u "$tmp_dir/apply.log" "$tmp_dir/delta.remote" > "$tmp_dir/delta.diff"; then
  cat "$tmp_dir/delta.diff" >&2
  fail "remote migration delta does not match the migrations reported as applied by the governed release"
fi

{
  echo '['
  first=1
  while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    shopt -s nullglob
    matches=("$migrations_dir/${version}_"*.sql)
    shopt -u nullglob
    ((${#matches[@]} == 1)) || fail "expected exactly one canonical migration file for applied version $version; found ${#matches[@]}"
    filename="$(basename "${matches[0]}")"
    commit_sha="$(git log -1 --format='%H' -- "${matches[0]}" 2>/dev/null || true)"
    commit_subject="$(git log -1 --format='%s' -- "${matches[0]}" 2>/dev/null || true)"
    origin_pr="$(grep -oE '#[0-9]+' <<< "$commit_subject" | head -n1 | tr -d '#' || true)"

    [[ "$first" -eq 1 ]] || echo ','
    first=0
    printf '  {"version":"%s","filename":"%s","core_commit_sha":"%s","originating_pr":%s}' \
      "$version" "$filename" "${commit_sha:-unknown}" \
      "$( [[ -n "$origin_pr" ]] && printf '"%s"' "$origin_pr" || printf 'null' )"
  done < "$tmp_dir/delta.remote"
  echo
  echo ']'
} > "$out_applied"

cat > "$out_json" <<EOF
{
  "status": "success",
  "workflow_run_id": "${GITHUB_RUN_ID:-local}",
  "workflow_run_attempt": "${GITHUB_RUN_ATTEMPT:-local}",
  "core_commit_sha": "${GITHUB_SHA:-$(git rev-parse HEAD)}",
  "deployment_actor": "${GITHUB_ACTOR:-local}",
  "production_project_ref": "${SUPABASE_PROJECT_REF:-unknown}",
  "applied_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "previous_production_max_version": "${previous_max:-none}",
  "new_production_max_version": "${new_max:-none}",
  "applied_versions": $(cat "$out_applied")
}
EOF

cat "$out_json"
