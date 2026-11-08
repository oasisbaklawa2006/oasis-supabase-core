#!/usr/bin/env bash
# STRICT ONE-TIME WITHDRAWAL: two never-production-applied Core #492 migrations.
# This is NOT a general migration-history exemption. It verifies the exact
# original protected merge, original Git blobs, immutable withdrawal evidence,
# and atomic removal of both paths. Do not expand the allowlist casually.

core492_withdrawal_allowed() {
  local path="${1:-}" original_parent="${2:-}" result_ref="${3:-}"
  local previous_sha expected_sha actual_sha manifest_sha
  local origin='678fa78da53f0e92c5aa8a908376a5eb5189393a'
  local first='supabase/migrations/20261107123000_studio_private_raw_media_staging_v1.sql'
  local second='supabase/migrations/20261107124500_studio_private_media_permission_scope_v1.sql'
  local evidence='docs/reconciliation/core492-never-applied-withdrawal-20261108.md'

  [[ "$original_parent" == "$origin" ]] || return 1
  [[ -n "$result_ref" ]] || return 1
  case "$path" in
    "$first") expected_sha='9b7af5da3344e0d3c1e2fe65a6f4b15f7930b55c' ;;
    "$second") expected_sha='29147e6abe4cd712781c1eb2b11fc95b48eef426' ;;
    *) return 1 ;;
  esac

  actual_sha="$(git rev-parse --verify "${origin}:${path}" 2>/dev/null)" || return 1
  [[ "$actual_sha" == "$expected_sha" ]] || return 1
  manifest_sha="$(git rev-parse --verify "${result_ref}:${evidence}" 2>/dev/null)" || return 1
  [[ "$manifest_sha" == 'ffc94b85f724b77d6f10aefbf7b3a52292173397' ]] || return 1

  # This exception must withdraw the entire two-file staging train atomically;
  # both paths must be absent in the resulting commit, never just one.
  if git cat-file -e "${result_ref}:${first}" 2>/dev/null ||
     git cat-file -e "${result_ref}:${second}" 2>/dev/null; then
    return 1
  fi
  return 0
}
