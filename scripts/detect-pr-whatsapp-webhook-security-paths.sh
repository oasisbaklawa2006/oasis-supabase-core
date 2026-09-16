#!/usr/bin/env bash
# Emit "true" when the PR diff touches WhatsApp webhook security paths.
set -euo pipefail

base_ref="${1:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "detect-pr-whatsapp-webhook-security-paths: git worktree required" >&2
  exit 1
fi

mapfile -t changed_files < <(git diff --name-only "origin/${base_ref}"...HEAD 2>/dev/null || git diff --name-only "${base_ref}"...HEAD)
(( ${#changed_files[@]} > 0 )) || changed_files=()

python3 - "${changed_files[@]}" <<'PY'
import sys

changed = sys.argv[1:]
prefixes = (
    "supabase/functions/whatsapp-webhook/",
    "supabase/functions/_shared/whatsappWebhookSecurity.ts",
    "supabase/functions/_shared/whatsappWebhookSecurity.test.ts",
    "supabase/functions/_shared/whatsappWebhookBoundary.ts",
    "supabase/functions/_shared/whatsappWebhookBoundary.test.ts",
    "supabase/functions/_shared/whatsappWebhookDurablePersistence.ts",
    "supabase/functions/_shared/whatsappWebhookDurablePersistence.test.ts",
    "supabase/functions/_shared/wa-governance/resolveWebhookCompany.ts",
    "supabase/functions/_shared/wa-governance/resolveWebhookCompany.test.ts",
    ".github/workflows/sync-whatsapp-edge-secrets.yml",
    ".github/workflows/whatsapp-webhook-security.yml",
    "docs/security/WHATSAPP_WEBHOOK_RUNTIME_EVIDENCE_2026-07-31.md",
    "docs/security/WHATSAPP_CLICK2API_RUNTIME_EVIDENCE_2026-08-01.md",
)

print("true" if any(path.startswith(prefix) for path in changed for prefix in prefixes) else "false")
PY
