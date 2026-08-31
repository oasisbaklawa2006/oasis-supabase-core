# Stage 2 protected historical corpus — owner input specification

Stage 2 accepts **authorized raw WhatsApp exports** directly (no sanitization required when owner authorizes).

## Owner workflow (Command 10)

1. Upload or mount the export outside Git:

   `protected-corpus/oasis-b2b-2/WhatsApp Chat - Oasis B2B 2.zip`

   (or extracted `protected-corpus/oasis-b2b-2/_chat.txt`)

2. Run full Stage 2 certification:

```bash
export WA_PROTECTED_CORPUS_PATH="protected-corpus/oasis-b2b-2/WhatsApp Chat - Oasis B2B 2.zip"
unset DATABASE_URL   # fail-closed if production ref present
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
deno run --allow-read --allow-write --allow-env --allow-run --allow-net \
  scripts/whatsapp-stage2-historical/run.ts
```

3. Ingest-only (parse/segment/label, no Core DB):

```bash
deno run --allow-read --allow-write --allow-env --allow-run \
  scripts/whatsapp-stage2-historical/run.ts --ingest-only "$WA_PROTECTED_CORPUS_PATH"
```

## Pipeline

```
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

| Form | Notes |
| --- | --- |
| `.zip` containing `_chat.txt` | Standard WhatsApp export archive |
| `.txt` / `_chat.txt` | Native bracket-timestamp export |

## Benchmark

- Aggregate governed score ≥ 95%
- All zero-tolerance counters = 0 (see `run.ts`)
- Full message reconciliation required

## Blockers observed (2026-08-31)

1. **Corpus mount** — authorized `WhatsApp Chat - Oasis B2B 2.zip` (~846,850 bytes) not synced to this VM. Re-attach or copy to `protected-corpus/oasis-b2b-2/` and set `WA_PROTECTED_CORPUS_PATH`.
2. **Cert DB** — if `supabase start` fails on Realtime init, bootstrap loopback Postgres:

```bash
bash scripts/whatsapp-stage2-historical/bootstrap_cert_db.sh
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
```

Never use production `DATABASE_URL` (`tcxvcatsqqertcnycuop`).

## Sample validation (2026-08-31)

Synthetic sample `protected-corpus/sample/b2b_group_chat.txt` — harness **PASS** (6 windows, benchmark 1.0, zero-tolerance 0). Full historical certification remains blocked until owner corpus is mounted.
