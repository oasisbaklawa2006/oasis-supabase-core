# Stage 2 protected historical corpus — owner input specification

Stage 2 is **blocked** until owner-provided sanitized corpus is available outside Git.

## Required declaration when blocked

`STAGE 2 HISTORICAL CORPUS — BLOCKED ON OWNER-PROVIDED CORPUS`

## Accepted input

| Item | Requirement |
| --- | --- |
| Format | JSON matching CERT-A golden corpus schema (`scripts/whatsapp-autonomy-eval/fixture_schema.ts`) |
| Delivery | File on secure host accessible to cert runner VM, **not** committed to Git |
| Env var | `WA_PROTECTED_CORPUS_PATH=/secure/path/sanitized_historical_v1.json` |
| CLI | `deno run --allow-all scripts/whatsapp-stage2-historical/run.ts /secure/path/sanitized_historical_v1.json` |

## Sanitization rules (mandatory)

- Replace real phone numbers with stable pseudonyms (`SENDER_001`, …)
- Replace customer/legal names with stable IDs (`CUSTOMER_001`, …)
- Preserve relational structure: same-sender, employee vs customer, forwarding, corrections, timestamps, media types
- Remove payment screenshots, UTRs, addresses, credentials, and raw attachments
- Never commit raw WhatsApp exports

## Corpus content expectations

Representative historical Oasis WhatsApp operating patterns where present in source material. Missing categories are reported separately — do not invent balance.

## Synthetic reference only (not Stage 2 substitute)

- `scripts/whatsapp-autonomy-eval/fixtures/sanitized_golden_v1.json` — 12-case synthetic CERT-A set for CI
- Stage 1B fixtures — synthetic media only; **closed** on run `b7635232-a9a3-49d8-806a-e749a2b8d8f9`

## Benchmark bar

- Aggregate governed benchmark ≥ 95%
- All zero-tolerance dangerous counters = 0 (see `scripts/whatsapp-stage2-historical/run.ts`)

## Artifact

Blocked or completed runs emit `artifacts/wa-stage2-historical/report.json` (sanitized metrics only).
