#!/usr/bin/env bash
# Emit edge governance path scope for the current PR diff.
# Usage: detect-pr-edge-governance-paths.sh [base_ref] [static|runtime|any]
set -euo pipefail

base_ref="${1:-main}"
scope="${2:-any}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "detect-pr-edge-governance-paths: git worktree required" >&2
  exit 1
fi

mapfile -t changed_files < <(git diff --name-only "origin/${base_ref}"...HEAD 2>/dev/null || git diff --name-only "${base_ref}"...HEAD)
(( ${#changed_files[@]} > 0 )) || changed_files=()

python3 - "$scope" "${changed_files[@]}" <<'PY'
import fnmatch
import sys

scope = sys.argv[1]
changed = sys.argv[2:]

static_patterns = [
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
    "scripts/wait-for-supabase-preview-check.sh",
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

runtime_patterns = [
    "supabase/config.toml",
    "supabase/functions/**",
    "supabase/.env.preview",
    "scripts/materialize-supabase-env-preview.sh",
    "scripts/upload-preview-dotenvx-keys.sh",
    "scripts/verify-preview-env-decryptable.sh",
    "scripts/ensure-supabase-preview-branch.sh",
    "scripts/ensure-supabase-preview-branch.py",
    "scripts/supabase_preview_branch_lib.py",
    "scripts/classify-supabase-preview-check.py",
    "scripts/wait-for-current-pr-preview-ref.sh",
    "scripts/wait-for-supabase-preview-check.sh",
    "scripts/resolve-current-pr-preview-ref.sh",
    "scripts/resolve-current-pr-preview-ref-from-branches.py",
    "scripts/check-preview-edge-runtime-secrets-readiness.sh",
]


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


static = any(matches(path, static_patterns) for path in changed)
runtime = any(matches(path, runtime_patterns) for path in changed)

if scope == "static":
    print("true" if static else "false")
elif scope == "runtime":
    print("true" if runtime else "false")
else:
    print("true" if (static or runtime) else "false")
PY
