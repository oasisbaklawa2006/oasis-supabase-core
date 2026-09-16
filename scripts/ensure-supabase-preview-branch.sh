#!/usr/bin/env bash
# Ensure the current PR has a governed Supabase preview branch when GitHub Preview
# was skipped for edge-only changes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
python3 scripts/ensure-supabase-preview-branch.py
