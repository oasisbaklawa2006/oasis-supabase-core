# Preview Edge Runtime Secrets (WhatsApp certification)

This document describes how approved **non-production** Edge Runtime secrets reach Supabase preview branches without manual dashboard pasting per transient branch.

## Scope

| Secret | Preview branches | Production (`tcxvcatsqqertcnycuop`) |
| --- | --- | --- |
| `GEMINI_API_KEY` | Yes — minimum set for Stage-1B media certification | Governed separately (dashboard / production CLI) |
| `WA_STAGE1B_CERT_SECRET` | Yes — independent confidential bearer for preview certification runner auth only | Governed separately; never derived from `GEMINI_API_KEY` |
| `WHATSAPP_MEDIA_ALLOWED_HOSTS` | Optional — workers also auto-allow the injected `SUPABASE_URL` host for cert fixture Storage | Governed separately when staging serves media from project Storage |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Supabase-generated per branch | Supabase-generated |
| Preview `DATABASE_URL` | Never copied into Cursor VM | N/A |

Never commit plaintext secret values. Production and preview credentials must not be mixed.

## Mechanism (canonical)

Two complementary layers:

### 1. Branching configuration (`config.toml`)

`supabase/config.toml` declares preview Edge Runtime secret **names**:

```toml
[edge_runtime.secrets]
GEMINI_API_KEY = "env(GEMINI_API_KEY)"
WHATSAPP_MEDIA_ALLOWED_HOSTS = "env(WHATSAPP_MEDIA_ALLOWED_HOSTS)"
WA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"
```

The Supabase branching executor applies this on preview deploy. Values come from encrypted branching env (below).

### 2. Encrypted preview env (Supabase-native, required for ephemeral previews)

Ephemeral PR preview sub-clouds are **not** writable through the connected Supabase Management API account. Provision preview Edge Runtime secrets through encrypted `supabase/.env.preview`:

1. One-time (owner workstation, value never committed):

   ```bash
   npx @dotenvx/dotenvx set GEMINI_API_KEY "<oasis-runtime-gemini-key>" -f supabase/.env.preview
   npx @dotenvx/dotenvx set WA_STAGE1B_CERT_SECRET "<independent-cert-secret>" -f supabase/.env.preview
   npx supabase secrets set --env-file supabase/.env.keys --project-ref tcxvcatsqqertcnycuop
   ```

2. Commit **only** `supabase/.env.preview` (encrypted). Keep `supabase/.env.keys` out of Git (already gitignored).

3. On each preview branch deploy, the branching executor decrypts `.env.preview` and injects Edge Runtime secrets into the current PR preview sub-cloud.

### 3. CI sync workflow (encrypted env refresh + readiness)

`.github/workflows/sync-preview-cert-edge-secrets.yml`:

- Resolves the **current PR preview ref** dynamically from the successful Supabase Preview check-run.
- Materializes encrypted `supabase/.env.preview` from GitHub Actions secrets (`GEMINI_API_KEY`, `WA_STAGE1B_CERT_SECRET`).
- Uploads dotenvx decryption keys to production (`tcxvcatsqqertcnycuop`) only — never to preview refs.
- Commits refreshed encrypted preview env when values rotate.
- Hard-fails if target ref equals production.
- Never logs secret values.
- Verifies readiness through the in-preview cert runner probe.

The workflow also runs on pull requests that touch preview secret configuration.

## Governance

`scripts/check-preview-edge-runtime-secrets-config.sh` fails CI when:

- `[edge_runtime.secrets]` or required secret declarations are missing from `config.toml`
- The sync workflow or this document is removed
- Production ref guard is missing from the sync workflow
- The sync workflow attempts Management API writes to ephemeral preview refs
- Stale historical preview refs remain in defaults or docs

## Preview migration ledger compatibility

If a forward migration on a PR branch was **resequenced** after an earlier preview branch already applied the earlier timestamp, Supabase Preview fails with `Remote migration versions not found in local migrations directory`.

The canonical fix is a **no-op ledger compatibility stub** at the earlier version (listed in `supabase/preview-migration-ledger-compat.txt`) plus the forward migration at the new timestamp. Preview branches that already applied the patch under the old version reconcile without re-running destructive DDL; fresh clean replays apply the forward patch only.

## Stage-1B certification

After sync, confirm readiness by running the in-preview cert orchestrator (no VM preview DB/service-role required):

```bash
deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts
```

The preview cert runner probes `GEMINI_API_KEY` inside Edge Runtime before scoring fixtures. A missing secret yields `MISSING_CERT_EDGE_RUNTIME_SECRET:GEMINI_API_KEY`.

## Owner one-time setup checklist

1. Add GitHub repository secret `GEMINI_API_KEY` (Oasis runtime Gemini credential; same provider key used for production worker path).
2. Add GitHub repository secret `WA_STAGE1B_CERT_SECRET` (strong random independent value for preview certification auth only).
3. Ensure repository secrets `SUPABASE_ACCESS_TOKEN`, `GEMINI_API_KEY`, and `WA_STAGE1B_CERT_SECRET` are configured (production Edge credentials remain in the production Supabase project separately).
4. Let CI materialize encrypted `supabase/.env.preview` and upload dotenvx keys to production on the next PR sync/governance run.
5. Rerun Stage-1B: `deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts`.
