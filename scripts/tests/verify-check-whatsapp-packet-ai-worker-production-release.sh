#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bash scripts/check-whatsapp-packet-ai-worker-production-release.sh
echo "WhatsApp packet AI worker production release governance regression passed."

# Regression: signing authority is restricted to the protected worker deploy job.
checker=scripts/check-whatsapp-webhook-production-release.sh
grep -Fq 'worker deploy signing permissions differ from approved least-privilege set' "$checker"
grep -Fq 'unexpected job-level permissions override in worker release' "$checker"
grep -Fq 'environment: supabase-production' "$checker"
