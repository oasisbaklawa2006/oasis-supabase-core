#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PYTHONPATH=scripts python3 - <<'PY'
from supabase_preview_branch_lib import preview_check_allows_failed_branch_wait

failed = {"status": "MIGRATIONS_FAILED"}
assert preview_check_allows_failed_branch_wait(failed, "missing")
assert preview_check_allows_failed_branch_wait(failed, "pending")
assert preview_check_allows_failed_branch_wait(failed, "success")
assert not preview_check_allows_failed_branch_wait(failed, "failed")
assert not preview_check_allows_failed_branch_wait(failed, "skipped")
assert not preview_check_allows_failed_branch_wait({"status": "RUNNING_MIGRATIONS"}, "pending")
assert not preview_check_allows_failed_branch_wait({"status": "FUNCTIONS_FAILED"}, "failed")
print("Preview failed-state retry convergence contract passed.")
PY
