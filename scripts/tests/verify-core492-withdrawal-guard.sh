#!/usr/bin/env bash
# Non-destructive adversarial tests of the exact-once Core #492 withdrawal.
# Synthetic commits are unreachable Git objects only: no branch or worktree
# is changed, no SQL is executed, and no production resource is accessed.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo_root"
source scripts/lib/core492-withdrawal-guard.sh

origin='678fa78da53f0e92c5aa8a908376a5eb5189393a'
first='supabase/migrations/20261107123000_studio_private_raw_media_staging_v1.sql'
second='supabase/migrations/20261107124500_studio_private_media_permission_scope_v1.sql'
third='supabase/migrations/20261107114000_product_media_unapproved_metadata_guard.sql'
evidence='docs/reconciliation/core492-never-applied-withdrawal-20261108.md'
first_sha='9b7af5da3344e0d3c1e2fe65a6f4b15f7930b55c'
second_sha='29147e6abe4cd712781c1eb2b11fc95b48eef426'
evidence_sha='ffc94b85f724b77d6f10aefbf7b3a52292173397'

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

reject() {
  local label="$1"
  shift
  if core492_withdrawal_allowed "$@"; then
    echo "FAIL: withdrawal guard improperly accepted $label" >&2
    exit 1
  fi
}

# Assert original Git blobs and manifest really have the hashes hard-pinned in
# the guard. SHA identities cannot be changed without changing the Git commit.
[[ "$(git rev-parse "$origin:$first")" == "$first_sha" ]]
[[ "$(git rev-parse "$origin:$second")" == "$second_sha" ]]
[[ "$(git rev-parse "HEAD:$evidence")" == "$evidence_sha" ]]
git cat-file -e "$origin:$third"

# Verify the real PR success path, including HEAD being an extra commit after
# the original two-file withdrawal. The squash on protected main has one child.
core492_withdrawal_allowed "$first" "$origin" HEAD
core492_withdrawal_allowed "$second" "$origin" HEAD

bad_evidence="$(printf '%s\n' 'tampered evidence is never valid' | git hash-object -w --stdin)"
bad_sql="$(printf '%s\n' 'select unsafe_test_payload;' | git hash-object -w --stdin)"

# Build commits through an isolated Git index; never touch the real index or
# checkout. All commits are disposable object-only fixtures with no refs.
make_fixture() {
  local label="$1" base="$2" change="$3" evidence_mode="$4"
  local idx="$scratch/$label.index" tree
  GIT_INDEX_FILE="$idx" git read-tree "$base"

  case "$change" in
    both)
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$first"
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$second"
      ;;
    first)
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$first"
      ;;
    second)
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$second"
      ;;
    extra)
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$first"
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$second"
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$third"
      ;;
    reintroduce)
      GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$first_sha,$first"
      ;;
    tamper-source)
      GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$bad_sql,$first"
      ;;
    none) ;;
    *)
      echo "Unknown fixture change: $change" >&2
      exit 1
      ;;
  esac

  case "$evidence_mode" in
    valid)
      GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$evidence_sha,$evidence"
      ;;
    bad)
      GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$bad_evidence,$evidence"
      ;;
    missing)
      GIT_INDEX_FILE="$idx" git update-index --force-remove "$evidence"
      ;;
    keep) ;;
    *)
      echo "Unknown evidence mode: $evidence_mode" >&2
      exit 1
      ;;
  esac

  tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
  GIT_AUTHOR_NAME='Guard Regression' GIT_AUTHOR_EMAIL='guard@example.invalid' \
    GIT_COMMITTER_NAME='Guard Regression' GIT_COMMITTER_EMAIL='guard@example.invalid' \
    git -c commit.gpgsign=false commit-tree "$tree" -p "$base" -m "Synthetic $label"
}

good="$(make_fixture valid-both "$origin" both valid)"
core492_withdrawal_allowed "$first" "$origin" "$good"
core492_withdrawal_allowed "$second" "$origin" "$good"

# No partial or two-commit staged withdrawal may exploit the atomic exception.
only_first="$(make_fixture partial-first "$origin" first valid)"
only_second="$(make_fixture partial-second "$origin" second valid)"
split="$(make_fixture split-second "$only_first" second keep)"
reject 'first file only' "$first" "$origin" "$only_first"
reject 'second file only' "$second" "$origin" "$only_second"
reject 'split across two commits' "$first" "$origin" "$split"

# Exact manifest SHA and its presence at initial withdrawal are mandatory.
missing="$(make_fixture missing-proof "$origin" both missing)"
tampered="$(make_fixture altered-proof "$origin" both bad)"
reject 'missing evidence' "$first" "$origin" "$missing"
reject 'tampered evidence' "$first" "$origin" "$tampered"

# An otherwise correct rollback must not delete any third migration.
extra="$(make_fixture unrelated-delete "$origin" extra valid)"
reject 'unrelated migration deletion' "$first" "$origin" "$extra"

# Reusing the exception against another parent/path is always forbidden.
reject 'wrong original parent' "$first" "$only_first" "$good"
reject 'unapproved migration path' "$third" "$origin" "$good"
reject 'non-commit result reference' "$first" "$origin" "$(git rev-parse "$good^{tree}")"

# Evidence mutation or file reintroduction AFTER the original deletion fails.
late_tamper="$(make_fixture late-tamper "$good" none bad)"
late_readd="$(make_fixture late-readd "$good" reintroduce keep)"
reject 'later manifest mutation' "$first" "$origin" "$late_tamper"
reject 'later file reintroduction' "$first" "$origin" "$late_readd"

# A different source history with an altered original SQL blob cannot claim
# the immutable #492 merge as its parent.
fake_origin="$(make_fixture fake-source "$origin" tamper-source valid)"
fake_withdraw="$(make_fixture fake-withdraw "$fake_origin" both valid)"
reject 'changed source origin' "$first" "$fake_origin" "$fake_withdraw"

# Benign successive commits after an atomic, evidenced withdrawal remain
# acceptable: branch review fixes must not force rewriting canonical history.
benign="$(make_fixture benign-follow-up "$good" none keep)"
core492_withdrawal_allowed "$first" "$origin" "$benign"
core492_withdrawal_allowed "$second" "$origin" "$benign"

echo 'verify-core492-withdrawal-guard.sh: all atomicity, provenance and replay cases passed'
