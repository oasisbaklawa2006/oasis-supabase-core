#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

provider='supabase/functions/whatsapp-packet-ai-worker/geminiProvider.ts'
test_file='supabase/functions/whatsapp-packet-ai-worker/geminiProvider.test.ts'

for file in "$provider" "$test_file"; do
  [[ -f "$file" ]] || { echo "GEMINI RETRY CONTRACT VIOLATION: missing $file" >&2; exit 1; }
done

grep -Fq 'export const GEMINI_TIMEOUT_MS = 90_000;' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: total provider budget must remain 90 seconds' >&2; exit 1; }
grep -Fq 'export const GEMINI_MAX_ATTEMPTS = 3;' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: retry attempts must remain bounded at 3' >&2; exit 1; }
grep -Fq 'export const GEMINI_RETRY_DELAYS_MS = [750, 2_000] as const;' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: retry delays changed' >&2; exit 1; }
grep -Fq 'status === 408 || status === 429 || (status >= 500 && status <= 599)' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: transient HTTP classification widened or removed' >&2; exit 1; }
grep -Fq 'x-goog-api-key' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: direct Gemini credential header missing' >&2; exit 1; }
grep -Fq 'gemini-3.7-flash' "$provider" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: frozen Gemini model changed' >&2; exit 1; }
if grep -Eq 'ai\.gateway\.lovable\.dev|openrouter\.ai|openai/' "$provider"; then
  echo 'GEMINI RETRY CONTRACT VIOLATION: alternate provider/fallback introduced' >&2
  exit 1
fi

grep -Fq 'transient provider 503 retries and can recover' "$test_file" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: recovery regression test missing' >&2; exit 1; }
grep -Fq 'transient provider failure is bounded and remains fail-closed' "$test_file" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: exhaustion regression test missing' >&2; exit 1; }
grep -Fq 'non-transient provider HTTP failure does not retry' "$test_file" \
  || { echo 'GEMINI RETRY CONTRACT VIOLATION: non-transient regression test missing' >&2; exit 1; }

echo 'WhatsApp Gemini retry contract check passed.'
