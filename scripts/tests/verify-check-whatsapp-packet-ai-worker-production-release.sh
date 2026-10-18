#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bash scripts/check-whatsapp-packet-ai-worker-production-release.sh
echo "WhatsApp packet AI worker production release governance regression passed."
