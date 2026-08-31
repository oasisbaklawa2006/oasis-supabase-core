# Stage 2 protected historical corpus — owner input specification

Stage 2 accepts **authorized raw WhatsApp exports** directly (no sanitization
required when owner authorizes).

## Owner workflow (Command 10)

1. Upload or mount the export outside Git:

   `protected-corpus/oasis-b2b-2/WhatsApp Chat - Oasis B2B 2.zip`

   (or extracted `protected-corpus/oasis-b2b-2/_chat.txt`)

2. Run full Stage 2 certification:

```bash
export WA_PROTECTED_CORPUS_PATH="protected-corpus/oasis-b2b-2/WhatsApp Chat - Oasis B2B 2.zip"
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
deno run --allow-read --allow-write --allow-env --allow-run --allow-net \
  scripts/whatsapp-stage2-historical/run.ts
```

Loopback-only enforcement is implemented in `database_target.ts` (runtime
validation rejects non-local hosts and production project refs). Unsetting or
omitting a production `DATABASE_URL` is a convenience only; it is **not** the
safety guarantee.

3. Ingest-only (parse/segment/label, no Core DB):

```bash
deno run --allow-read --allow-write --allow-env --allow-run \
  scripts/whatsapp-stage2-historical/run.ts --ingest-only "$WA_PROTECTED_CORPUS_PATH"
```

## Pipeline

```text
RAW WHATSAPP TXT/ZIP
  → parse_export.ts
  → segment.ts (context windows; not 1 message = 1 order)
  → expectations.ts (evidence-derived labels; AI does not self-grade)
  → Core evaluation (isolated cert DB only)
  → artifacts/wa-stage2-historical/report.json (no raw bodies)
```

## Hard boundaries

- Never commit raw export to Git (`protected-corpus/` is gitignored)
- Never mutate production `tcxvcatsqqertcnycuop`
- No customer contact, live orders, or production queue writes
- Historical data is read-only certification evidence

## Accepted formats

| Form                          | Notes                            |
| ----------------------------- | -------------------------------- |
| `.zip` containing `_chat.txt` | Standard WhatsApp export archive |
| `.txt` / `_chat.txt`          | Native bracket-timestamp export  |

## Benchmark

- Aggregate governed score ≥ 95%
- All zero-tolerance counters evaluated and = 0 (see `run.ts`)
- Full message reconciliation required
- Full corpus execution required (partial runs cannot PASS)

## Cert DB (local only)

Stage 2 Core evaluation uses the same governed local stack as CERT-A:

```bash
supabase start
supabase db reset --local
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
```

`database_target.ts` fail-closes on non-loopback hosts and production project
refs (`tcxvcatsqqertcnycuop`). Never point Stage 2 at production.

## Stage 2 certification status (2026-08-31)

**PROVISIONAL / INVALIDATED** — prior `wa-stage2-historical/v2` PASS (benchmark
1.0) is not authoritative after routing/reconciliation integrity repairs. A
fresh full protected-corpus run under schema `wa-stage2-historical/v3` is
required before release use.

Corpus hash reference (unchanged export):
`ae6b6bfecfdce8b6873a650815d14e3d2f929ef1e47ddf880397357d36c2f0c9`

Synthetic sample `protected-corpus/sample/b2b_group_chat.txt` remains available
for harness smoke tests.
