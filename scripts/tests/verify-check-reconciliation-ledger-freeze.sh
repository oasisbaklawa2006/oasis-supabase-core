#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-reconciliation-ledger-freeze.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir/docs/reconciliation" "$dir/scripts/tests"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name 'Reconciliation Freeze Guard Test'
  git -C "$dir" config user.email 'reconciliation-freeze@example.invalid'
  printf '%s\n' 'version,status' '20260818000000,remote' > "$dir/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
  git -C "$dir" add .
  git -C "$dir" commit -q -m base
}

run_checker() {
  local dir="$1" base="$2"
  (cd "$dir" && bash "$checker" "$base")
}

expect_fail() {
  local dir="$1" base="$2" pattern="$3"
  set +e
  run_checker "$dir" "$base" >"$dir/check.out" 2>"$dir/check.err"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected reconciliation freeze checker to fail in $dir" >&2
    exit 1
  fi
  grep -Eqi "$pattern" "$dir/check.err"
}

# 1. An unchanged frozen ledger passes.
case1="$test_root/unchanged"
new_repo "$case1"
base1="$(git -C "$case1" rev-parse HEAD)"
run_checker "$case1" "$base1" >/dev/null

# 2. Extending frozen evidence without an incident marker fails closed.
case2="$test_root/no-marker"
new_repo "$case2"
base2="$(git -C "$case2" rev-parse HEAD)"
printf '%s\n' '20261001233000,represented_remote' >> "$case2/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
git -C "$case2" add . && git -C "$case2" commit -q -m ledger-only
expect_fail "$case2" "$base2" 'without.*production-lineage-incident-approved'

# 3. A marker alone is insufficient; a reconciliation test must change too.
case3="$test_root/marker-no-test"
new_repo "$case3"
base3="$(git -C "$case3" rev-parse HEAD)"
printf '%s\n' '20261001233000,represented_remote' >> "$case3/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
cat > "$case3/docs/reconciliation/incident.md" <<'EOF'
-- production-lineage-incident-approved: fixture approval
EOF
git -C "$case3" add . && git -C "$case3" commit -q -m marker-no-test
expect_fail "$case3" "$base3" 'no dedicated reconciliation test'

# 4. A legitimate ledger extension with marker + test passes even when the
# marker appears early in a large diff. This reproduces the historical
# grep -q + pipefail SIGPIPE false-negative from release run 37097810160.
case4="$test_root/valid-large-diff"
new_repo "$case4"
base4="$(git -C "$case4" rev-parse HEAD)"
printf '%s\n' '20261001233000,represented_remote' >> "$case4/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
cat > "$case4/docs/reconciliation/incident.md" <<'EOF'
-- production-lineage-incident-approved: fixture approval
EOF
printf '%s\n' '# reconciliation regression fixture' > "$case4/scripts/tests/reconciliation-ledger-fixture.txt"
awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "evidence-line-%05d-padding-padding-padding-padding\n", i }' > "$case4/docs/reconciliation/zz-large-evidence.txt"
git -C "$case4" add . && git -C "$case4" commit -q -m valid-large-diff
run_checker "$case4" "$base4" >"$case4/check.out" 2>"$case4/check.err"
grep -q 'incident-approval marker and dedicated reconciliation test updates' "$case4/check.out"
if grep -qi 'broken pipe' "$case4/check.err"; then
  echo 'valid marker detection emitted Broken pipe' >&2
  exit 1
fi

echo 'verify-check-reconciliation-ledger-freeze.sh: all cases passed'
