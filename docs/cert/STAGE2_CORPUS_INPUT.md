# Stage 2 protected historical corpus — owner input specification

Stage 2 is **blocked** until owner-provided historical material is available outside Git.

## Required declaration when blocked

`STAGE 2 HISTORICAL CORPUS — BLOCKED ON OWNER-PROVIDED CORPUS`

## Owner workflow (single secure handoff)

1. Export the relevant historical WhatsApp chat or group (standard WhatsApp **Export chat** text format).
2. Place the export on a secure path accessible to the cert runner VM (local protected directory or mounted artifact). **Do not commit to Git.**
3. Point the sanitizer at the export and produce pseudonymized JSON:

```bash
export WA_PROTECTED_CORPUS_PATH=/secure/path/to/WhatsApp\ Chat\ with\ B2B\ Group.txt
deno run --allow-read --allow-write --allow-env \
  scripts/whatsapp-stage2-historical/sanitize.ts \
  --output /secure/path/sanitized_historical_v1.json \
  "$WA_PROTECTED_CORPUS_PATH"
```

4. Run Stage 2 harness on the sanitized JSON (read-only evaluation path):

```bash
export WA_PROTECTED_CORPUS_PATH=/secure/path/sanitized_historical_v1.json
deno run --allow-all scripts/whatsapp-stage2-historical/run.ts
```

Dry-run (counts and hash only — **no raw message bodies in output**):

```bash
deno run --allow-read --allow-env \
  scripts/whatsapp-stage2-historical/sanitize.ts --dry-run "$WA_PROTECTED_CORPUS_PATH"
```

## Accepted input formats

| Form | Notes |
| --- | --- |
| Native WhatsApp text export | `*.txt` / `_chat.txt` — Android/iOS bracket timestamps, multiline messages, `<attached:` / `image omitted`, forwarded markers |
| Directory of exports | All `*.txt` files under `WA_PROTECTED_CORPUS_PATH` when set to a directory |
| Pre-sanitized JSON | Golden corpus schema; passthrough validation only (no re-sanitization) |

## Sanitization rules (mandatory)

Implemented in `scripts/whatsapp-stage2-historical/sanitize.ts`:

- Deterministic pseudonyms for senders (`91XXXXXXXXXX` stable hash phones; `PARTICIPANT_*` display names)
- Phone numbers, emails, UTR/payment refs, and long account numerics removed from bodies
- Stable sender relationships preserved via hashed participant map
- Timestamps, message order, forwarding, corrections, and media type metadata preserved
- System/encryption boilerplate rejected (not scored)
- Output validates against Stage 2 / CERT-A golden corpus schema
- Raw export never committed; `.gitignore` covers `protected-corpus/` and `*.protected-corpus.json`

## Safety (read-only evidence)

Stage 2 harness and sanitizer:

- Do **not** contact customers or send WhatsApp replies
- Do **not** create live orders, verify live payments, or mutate production customer records
- Use isolated CERT-A database evaluation paths only (`database_target.ts` fail-closed guards)
- AI interpretation objects in sanitized cases are advisory stubs; Core scoring remains authority

## Corpus content expectations

Preserve the broad business mix present in the source export (orders, corrections, forwards, payment mentions, media references, general operations). Missing categories are reported in sanitizer dry-run `category_candidates` — do not invent balance.

## Synthetic reference only (not Stage 2 substitute)

- `scripts/whatsapp-autonomy-eval/fixtures/sanitized_golden_v1.json` — 12-case synthetic CERT-A set for CI
- Stage 1B fixtures — synthetic media only; **closed** on run `b7635232-a9a3-49d8-806a-e749a2b8d8f9`

## Benchmark bar

- Aggregate governed benchmark ≥ 95%
- All zero-tolerance dangerous counters = 0 (see `scripts/whatsapp-stage2-historical/run.ts`)

## Artifact

Blocked or completed runs emit `artifacts/wa-stage2-historical/report.json` (sanitized metrics only).

## Credentials

No additional owner secret is required for sanitization. Stage 2 execution requires the same isolated CERT database target configuration as CERT-A (`DATABASE_URL` to non-production cert DB only). Raw WhatsApp exports must remain outside Git.
