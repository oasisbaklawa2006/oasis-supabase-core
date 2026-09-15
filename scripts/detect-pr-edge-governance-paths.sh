#!/usr/bin/env bash
# Emit "true" when the PR diff touches Edge Function governance paths.
set -euo pipefail

base_ref="${1:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "detect-pr-edge-governance-paths: git worktree required" >&2
  exit 1
fi

mapfile -t changed_files < <(git diff --name-only "origin/${base_ref}"...HEAD 2>/dev/null || git diff --name-only "${base_ref}"...HEAD)
(( ${#changed_files[@]} > 0 )) || changed_files=()

python3 - "${changed_files[@]}" <<'PY'
import fnmatch
import sys

changed = sys.argv[1:]
patterns = [
    "supabase/config.toml",
    "supabase/functions/**",
    "scripts/check-edge-function-governance.sh",
    "scripts/check-edge-function-auth-registry.sh",
    "scripts/check-edge-function-source-reconciliation.sh",
    "scripts/check-whatsapp-webhook-recertification.sh",
    "scripts/check-studio-inbox-bridge-certification.sh",
    "scripts/check-integration-health-verification.sh",
    "scripts/check-edge-registry-config-reconciliation.sh",
    "scripts/check-whatsapp-gemini-retry-contract.sh",
    "scripts/check-edge-runtime-certification.sh",
    "scripts/check-preview-edge-runtime-secrets-config.sh",
    "scripts/check-preview-edge-runtime-secrets-readiness.sh",
    "scripts/resolve-current-pr-preview-ref.sh",
    "scripts/resolve-current-pr-preview-ref-from-branches.py",
    "scripts/ensure-supabase-preview-branch.sh",
    "scripts/ensure-supabase-preview-branch.py",
    "scripts/supabase_preview_branch_lib.py",
    "scripts/classify-supabase-preview-check.py",
    "scripts/wait-for-current-pr-preview-ref.sh",
    "scripts/materialize-supabase-env-preview.sh",
    "scripts/upload-preview-dotenvx-keys.sh",
    "scripts/verify-preview-env-decryptable.sh",
    "scripts/upload-production-dotenvx-key.py",
    "scripts/tests/verify-preview-edge-runtime-secrets-targeting.sh",
    "supabase/.env.preview",
    "docs/security/EDGE_FUNCTION_*.md",
    "docs/security/WHATSAPP_WEBHOOK_*.md",
    "docs/security/WHATSAPP_CLICK2API_*.md",
    "docs/security/WHATSAPP_STUDIO_INBOX_BRIDGE_*.md",
    "docs/security/INTEGRATION_HEALTH_*.md",
    "docs/security/edge-function-auth-registry-*.csv",
    "docs/security/edge-function-source-reconciliation-*.csv",
    ".github/workflows/edge-function-governance.yml",
]


def matches(path: str) -> bool:
    for pattern in patterns:
        if fnmatch.fnmatch(path, pattern):
            return True
    return False


print("true" if any(matches(path) for path in changed) else "false")
PY
