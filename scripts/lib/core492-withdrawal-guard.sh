#!/usr/bin/env bash
# EXACT-ONCE Core #492 withdrawal. Two immutable SQL histories were never
# applied in production. No generalized migration-history bypass is allowed.
# Guard runs under the protected history and base-monotonicity checkers.

core492_withdrawal_allowed() {
  local path="${1:-}" original_parent="${2:-}" result_ref="${3:-}"
  local actual_sha manifest_sha first_child next_parent changes
  local origin='678fa78da53f0e92c5aa8a908376a5eb5189393a'
  local first='supabase/migrations/20261107123000_studio_private_raw_media_staging_v1.sql'
  local second='supabase/migrations/20261107124500_studio_private_media_permission_scope_v1.sql'
  local evidence='docs/reconciliation/core492-never-applied-withdrawal-20261108.md'
  local first_blob='9b7af5da3344e0d3c1e2fe65a6f4b15f7930b55c'
  local second_blob='29147e6abe4cd712781c1eb2b11fc95b48eef426'
  local evidence_blob='ffc94b85f724b77d6f10aefbf7b3a52292173397'

  [[ "$original_parent" == "$origin" ]] || return 1
  [[ "$path" == "$first" || "$path" == "$second" ]] || return 1
  git cat-file -e "${result_ref}^{commit}" 2>/dev/null || return 1

  # The first-parent path MUST descend from the one specifically authorized
  # #492 merge. Locate the first child after that merge, even when a PR adds
  # cosmetic commits after its original atomic withdrawal. After squash this
  # is simply the protected squash commit itself.
  first_child="$(git rev-parse --verify "${result_ref}^{commit}" 2>/dev/null)" || return 1
  while :; do
    next_parent="$(git rev-parse --verify "${first_child}^1" 2>/dev/null)" || return 1
    [[ "$next_parent" != "$origin" ]] || break
    first_child="$next_parent"
  done

  actual_sha="$(git rev-parse --verify "${origin}:${first}" 2>/dev/null)" || return 1
  [[ "$actual_sha" == "$first_blob" ]] || return 1
  actual_sha="$(git rev-parse --verify "${origin}:${second}" 2>/dev/null)" || return 1
  [[ "$actual_sha" == "$second_blob" ]] || return 1

  # The EXACT two files must be removed in ONE initial child commit, with no
  # unrelated migration-file modifications, re-timestamping, or deletions.
  changes="$(git diff --name-status --no-renames "$origin" "$first_child" -- supabase/migrations 2>/dev/null)" || return 1
  [[ "$changes" == "$(printf 'D\t%s\nD\t%s' "$first" "$second")" ]] || return 1

  # Evidence must be present, immutable and hash-pinned at introduction AND
  # at the tip; an altered, missing, or later replaced manifest fails closed.
  manifest_sha="$(git rev-parse --verify "${first_child}:${evidence}" 2>/dev/null)" || return 1
  [[ "$manifest_sha" == "$evidence_blob" ]] || return 1
  manifest_sha="$(git rev-parse --verify "${result_ref}:${evidence}" 2>/dev/null)" || return 1
  [[ "$manifest_sha" == "$evidence_blob" ]] || return 1

  # No reintroduction of either withdrawn SQL file at the result ref.
  if git cat-file -e "${result_ref}:${first}" 2>/dev/null ||
     git cat-file -e "${result_ref}:${second}" 2>/dev/null; then
    return 1
  fi

  return 0
}
