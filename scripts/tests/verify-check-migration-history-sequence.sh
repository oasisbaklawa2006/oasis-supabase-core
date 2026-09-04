#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-migration-history-sequence.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir/supabase/migrations"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name 'Migration History Guard Test'
  git -C "$dir" config user.email 'migration-history@example.invalid'
  printf '%s\n' '-- activation base' > "$dir/supabase/migrations/20260828002100_base.sql"
  git -C "$dir" add .
  git -C "$dir" commit -q -m activation
}

expect_fail() {
  local dir="$1" base="$2" pattern="$3"
  set +e
  (cd "$dir" && bash "$checker" "$base") >"$dir/check.out" 2>"$dir/check.err"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Eqi "$pattern" "$dir/check.err"
}

# 1. A strictly increasing multi-commit train passes.
case1="$test_root/valid"
new_repo "$case1"
activation1="$(git -C "$case1" rev-parse HEAD)"
printf '%s\n' '-- first' > "$case1/supabase/migrations/20260828120000_first.sql"
git -C "$case1" add . && git -C "$case1" commit -q -m first
printf '%s\n' '-- second' > "$case1/supabase/migrations/20260828130000_second.sql"
git -C "$case1" add . && git -C "$case1" commit -q -m second
(cd "$case1" && bash "$checker" "$activation1") >/dev/null

# 2. The exact multi-commit bypass regression: commit one introduces a stale
# migration and commit two changes only docs. Full-history validation must still
# fail even though HEAD^ itself contains no migration change.
case2="$test_root/hidden-stale"
new_repo "$case2"
activation2="$(git -C "$case2" rev-parse HEAD)"
printf '%s\n' '-- future first' > "$case2/supabase/migrations/20260828120000_future.sql"
git -C "$case2" add . && git -C "$case2" commit -q -m future
printf '%s\n' '-- stale later' > "$case2/supabase/migrations/20260828110000_stale.sql"
git -C "$case2" add . && git -C "$case2" commit -q -m stale
printf '%s\n' 'docs only' > "$case2/README.md"
git -C "$case2" add . && git -C "$case2" commit -q -m docs
expect_fail "$case2" "$activation2" 'not strictly greater|prior canonical ceiling'

# 3. Modifying canonical migration history after activation fails.
case3="$test_root/modify"
new_repo "$case3"
activation3="$(git -C "$case3" rev-parse HEAD)"
printf '%s\n' '-- future' > "$case3/supabase/migrations/20260828120000_future.sql"
git -C "$case3" add . && git -C "$case3" commit -q -m future
printf '%s\n' '-- mutation' >> "$case3/supabase/migrations/20260828120000_future.sql"
git -C "$case3" add . && git -C "$case3" commit -q -m mutate
expect_fail "$case3" "$activation3" 'M of canonical migration history'

# 4. Duplicate versions introduced in separate commits fail.
case4="$test_root/duplicate"
new_repo "$case4"
activation4="$(git -C "$case4" rev-parse HEAD)"
printf '%s\n' '-- one' > "$case4/supabase/migrations/20260828120000_one.sql"
git -C "$case4" add . && git -C "$case4" commit -q -m one
printf '%s\n' '-- two' > "$case4/supabase/migrations/20260828120000_two.sql"
git -C "$case4" add . && git -C "$case4" commit -q -m two
expect_fail "$case4" "$activation4" 'collides'

# 5. Malformed activation-base SQL filenames fail closed and cannot disappear
# from the baseline ceiling inventory.
case5="$test_root/malformed-base"
new_repo "$case5"
printf '%s\n' '-- malformed' > "$case5/supabase/migrations/not-a-version.sql"
git -C "$case5" add . && git -C "$case5" commit -q -m malformed-base
activation5="$(git -C "$case5" rev-parse HEAD)"
expect_fail "$case5" "$activation5" 'activation base contains malformed'

# 6. Path traversal cannot weaken the authority directory.
set +e
(cd "$case1" && MIGRATIONS_DIR='../outside' bash "$checker" "$activation1") >"$case1/traversal.out" 2>"$case1/traversal.err"
status=$?
set -e
test "$status" -ne 0
grep -q 'MIGRATIONS_DIR must be repository-relative' "$case1/traversal.err"

# 7. A preview-ledger compatibility stub may preserve an older applied preview
# version below the canonical ceiling. It must be a marker-bearing exact no-op,
# and it must NOT advance or lower the canonical schema ceiling.
case7="$test_root/preview-compat-valid"
new_repo "$case7"
activation7="$(git -C "$case7" rev-parse HEAD)"
printf '%s\n' '-- canonical future' > "$case7/supabase/migrations/20260828120000_future.sql"
git -C "$case7" add . && git -C "$case7" commit -q -m future
cat > "$case7/supabase/migrations/20260828110000_preview_stub.sql" <<'SQL'
-- Preview ledger compatibility stub (non-production preview branches only).
-- Preview ledger compatibility: no schema mutation in this file.
select 1;
SQL
printf '%s\n' '20260828110000' > "$case7/supabase/preview-migration-ledger-compat.txt"
git -C "$case7" add . && git -C "$case7" commit -q -m preview-compat
printf '%s\n' '-- after compat' > "$case7/supabase/migrations/20260828130000_after.sql"
git -C "$case7" add . && git -C "$case7" commit -q -m after
(cd "$case7" && bash "$checker" "$activation7") >"$case7/check.out"
grep -q 'final_ceiling=20260828130000' "$case7/check.out"

# 8. Listing a stale version as preview-compatible can never exempt real schema
# work. The guard reads the file from its introducing commit and rejects any SQL
# other than the exact inert `select 1;` marker.
case8="$test_root/preview-compat-mutation"
new_repo "$case8"
activation8="$(git -C "$case8" rev-parse HEAD)"
printf '%s\n' '-- canonical future' > "$case8/supabase/migrations/20260828120000_future.sql"
git -C "$case8" add . && git -C "$case8" commit -q -m future
cat > "$case8/supabase/migrations/20260828110000_preview_stub.sql" <<'SQL'
-- Preview ledger compatibility: falsely claimed no-op.
create table public.should_never_pass(id bigint);
SQL
printf '%s\n' '20260828110000' > "$case8/supabase/preview-migration-ledger-compat.txt"
git -C "$case8" add . && git -C "$case8" commit -q -m malicious-compat
expect_fail "$case8" "$activation8" 'exact no-op stub'

# 9. The compatibility inventory itself fails closed on malformed entries.
case9="$test_root/preview-compat-malformed"
new_repo "$case9"
activation9="$(git -C "$case9" rev-parse HEAD)"
printf '%s\n' 'not-a-14-digit-version' > "$case9/supabase/preview-migration-ledger-compat.txt"
git -C "$case9" add . && git -C "$case9" commit -q -m malformed-compat-ledger
expect_fail "$case9" "$activation9" 'entry must be exactly 14 digits'

# 10. Path traversal cannot redirect the compatibility inventory to an
# attacker-controlled file outside the repository.
set +e
(cd "$case1" && PREVIEW_MIGRATION_LEDGER_COMPAT_FILE='../outside' bash "$checker" "$activation1") >"$case1/compat-traversal.out" 2>"$case1/compat-traversal.err"
status=$?
set -e
test "$status" -ne 0
grep -q 'PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative' "$case1/compat-traversal.err"

# 11. Post-introduction mutation of a compatibility stub is forbidden. Even if
# introduction validation passed, modifying the migration file must fail closed.
case11="$test_root/preview-compat-post-intro-mutation"
new_repo "$case11"
activation11="$(git -C "$case11" rev-parse HEAD)"
printf '%s\n' '-- canonical future' > "$case11/supabase/migrations/20260828120000_future.sql"
git -C "$case11" add . && git -C "$case11" commit -q -m future
cat > "$case11/supabase/migrations/20260828110000_preview_stub.sql" <<'SQL'
-- Preview ledger compatibility stub (non-production preview branches only).
-- Preview ledger compatibility: no schema mutation in this file.
select 1;
SQL
printf '%s\n' '20260828110000' > "$case11/supabase/preview-migration-ledger-compat.txt"
git -C "$case11" add . && git -C "$case11" commit -q -m preview-compat
cat > "$case11/supabase/migrations/20260828110000_preview_stub.sql" <<'SQL'
-- Preview ledger compatibility: mutated after introduction.
create table public.should_never_pass(id bigint);
SQL
git -C "$case11" add . && git -C "$case11" commit -q -m mutate-compat
expect_fail "$case11" "$activation11" 'of canonical migration history'

echo 'verify-check-migration-history-sequence.sh: all cases passed'
