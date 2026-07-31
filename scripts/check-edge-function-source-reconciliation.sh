#!/usr/bin/env bash
set -euo pipefail

registry="docs/security/edge-function-auth-registry-2026-07-31.csv"
reconciliation="docs/security/edge-function-source-reconciliation-2026-07-31.csv"

[[ -f "$registry" ]] || { echo "missing auth registry"; exit 1; }
[[ -f "$reconciliation" ]] || { echo "missing source reconciliation ledger"; exit 1; }

registry_count=$(( $(wc -l < "$registry") - 1 ))
reconciliation_count=$(( $(wc -l < "$reconciliation") - 1 ))
[[ "$registry_count" -eq 26 ]] || { echo "auth registry must contain 26 functions"; exit 1; }
[[ "$reconciliation_count" -eq 26 ]] || { echo "source ledger must contain 26 functions"; exit 1; }

registry_names=$(tail -n +2 "$registry" | cut -d, -f1 | sort)
reconciliation_names=$(tail -n +2 "$reconciliation" | cut -d, -f1 | sort)
[[ "$registry_names" == "$reconciliation_names" ]] || { echo "source ledger function set differs from auth registry"; exit 1; }

for fn in catalogue-ai-copy generate-product-attributes whatsapp-webhook whatsapp-studio-inbox-bridge; do
  grep -q "^${fn},.*supabase/functions/${fn}/index.ts," "$reconciliation" || {
    echo "canonical repository source not recorded for ${fn}"
    exit 1
  }
  [[ -f "supabase/functions/${fn}/index.ts" ]] || {
    echo "recorded canonical source missing from repository for ${fn}"
    exit 1
  }
done

grep -q '^generate-product-attributes,.*live-repository-drift,remain-quarantined$' "$reconciliation" || {
  echo "generate-product-attributes drift/quarantine control missing"
  exit 1
}

grep -q '^whatsapp-webhook,.*legacy-erp-central,canonical-source-present-high-risk,dedicated-recertification$' "$reconciliation" || {
  echo "whatsapp-webhook ownership or recertification control missing"
  exit 1
}

grep -q '^whatsapp-studio-inbox-webhook,.*missing-repository-source,reconstruct-or-retire$' "$reconciliation" || {
  echo "studio inbox webhook missing-source disposition not preserved"
  exit 1
}

if tail -n +2 "$reconciliation" | cut -d, -f1 | sort | uniq -d | grep -q .; then
  echo "duplicate function entries in source reconciliation ledger"
  exit 1
fi

echo "Edge Function source reconciliation verified: 26 live functions, 4 canonical sources present, 22 explicitly unresolved."
