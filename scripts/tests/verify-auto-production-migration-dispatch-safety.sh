#!/usr/bin/env bash
set -euo pipefail

# Contract: automatic production preflight never authorizes a production write.
# A protected main source merge is NOT a production deployment approval.
cd "$(dirname "$0")/../.."
workflow=.github/workflows/auto-production-migration-dispatch.yml

test -s "$workflow"
grep -Fq '  actions: read' "$workflow"
grep -Fq '  contents: read' "$workflow"
grep -Fq "github.event.workflow_run.conclusion == 'success'" "$workflow"
grep -Fq 'name: Report certified preflight awaiting explicit authorization' "$workflow"
grep -Fq 'Manual workflow_dispatch with deploy=true' "$workflow"

# Fail closed on any machine token able to start a workflow or an implicit
# production dispatch. Adjust only through new independently reviewed governance.
if grep -Eq '^[[:space:]]*actions:[[:space:]]*write([[:space:]]|$)|^[[:space:]]*gh[[:space:]]+workflow[[:space:]]+run([[:space:]]|$)|^[[:space:]]*-f[[:space:]]+deploy=true([[:space:]]|$)' "$workflow"; then
  echo 'FAIL: automatic migration preflight can initiate a production deployment' >&2
  exit 1
fi

echo 'PASS: automatic migration preflight is read-only; explicit owner dispatch remains required'
