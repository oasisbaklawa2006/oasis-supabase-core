#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

contract='supabase/functions/_shared/integrationRetryContract.ts'
test_file='supabase/functions/_shared/integrationRetryContract.test.ts'
provider='supabase/functions/_shared/geminiProvider.ts'

for file in "$contract" "$test_file" "$provider"; do
  [[ -f "$file" ]] || { echo "INTEGRATION RETRY CONTRACT VIOLATION: missing $file" >&2; exit 1; }
done

grep -Fq 'export type IntegrationRetryDisposition = "retryable" | "permanent";' "$contract" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: explicit retry disposition missing' >&2; exit 1; }
grep -Fq 'status === 408 || status === 429 || (status >= 500 && status <= 599)' "$contract" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: transient HTTP classification changed' >&2; exit 1; }
grep -Fq 'export async function executeWithBoundedRetry' "$contract" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: bounded retry executor missing' >&2; exit 1; }

grep -Fq 'from "./integrationRetryContract.ts"' "$provider" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: gemini provider must import shared contract' >&2; exit 1; }
grep -Fq 'return isTransientHttpStatus(status);' "$provider" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: gemini transient classification must delegate to shared contract' >&2; exit 1; }

grep -Fq 'bounded retry executes permanent failures without retrying' "$test_file" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: permanent failure regression test missing' >&2; exit 1; }
grep -Fq 'bounded retry recovers after transient failures' "$test_file" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: recovery regression test missing' >&2; exit 1; }
grep -Fq 'bounded retry exhausts attempts and fails closed' "$test_file" \
  || { echo 'INTEGRATION RETRY CONTRACT VIOLATION: exhaustion regression test missing' >&2; exit 1; }

echo 'Integration retry contract check passed.'
