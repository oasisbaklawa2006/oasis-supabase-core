# Preview Edge Runtime Secrets (WhatsApp certification)

This document describes how approved **non-production** Edge Runtime secrets reach Supabase preview branches without manual dashboard pasting per transient branch.

## Scope

| Secret | Preview branches | Production (`tcxvcatsqqertcnycuop`) |
| --- | --- | --- |
| `GEMINI_API_KEY` | Yes — minimum set for Stage-1B media certification | Governed separately (dashboard / production CLI) |
| `WHATSAPP_MEDIA_ALLOWED_HOSTS` | Yes — cert fixture storage host (`<preview-ref>.supabase.co`); also derived from injected `SUPABASE_URL` in workers | Governed separately when staging serves media from project Storage |
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
```

The Supabase branching executor applies this on preview deploy. Values come from encrypted branching env or CI sync (below).

### 2. Encrypted preview env (Supabase-native, optional bootstrap)

For Git-native auto-provisioning on **new** preview branches:

1. One-time (owner workstation, value never committed):

   ```bash
   npx @dotenvx/dotenvx set GEMINI_API_KEY "<oasis-runtime-gemini-key>" -f supabase/.env.preview
   npx supabase secrets set --env-file supabase/.env.keys --project-ref tcxvcatsqqertcnycuop
   ```

2. Commit **only** `supabase/.env.preview` (encrypted). Keep `supabase/.env.keys` out of Git (already gitignored).

3. On each preview branch deploy, the branching executor decrypts `.env.preview` and injects Edge Runtime secrets.

### 3. CI sync workflow (immediate + PR branches)

`.github/workflows/sync-preview-cert-edge-secrets.yml`:

- Sources `GEMINI_API_KEY` from GitHub Actions secret (same Oasis runtime credential).
- When GitHub repository secrets are unavailable, the sync workflow may resolve
`GEMINI_API_KEY` from the production Supabase secrets store (write-only in
dashboard; readable via Management API using `SUPABASE_ACCESS_TOKEN`) and
write it to the target preview branch. Secret values are never logged.
- Writes **only** to the pinned preview ref (default `jyezfiehhfgnvhzzffxr`).
- Sets `WHATSAPP_MEDIA_ALLOWED_HOSTS` to `<preview-ref>.supabase.co` so Stage-1B cert fixtures in public Storage pass governed media fetch (workers also auto-allow the injected `SUPABASE_URL` host).
- Hard-fails if target ref equals production.
- Never logs secret values.

Trigger manually:

```bash
gh workflow run sync-preview-cert-edge-secrets.yml \
  -f preview_project_ref=jyezfiehhfgnvhzzffxr
```

The workflow also runs on pull requests that touch preview secret configuration.

## Governance

`scripts/check-preview-edge-runtime-secrets-config.sh` fails CI when:

- `[edge_runtime.secrets]` or `GEMINI_API_KEY` declaration is missing from `config.toml`
- The sync workflow or this document is removed
- Production ref guard is missing from the sync workflow

## Preview migration ledger compatibility

If a forward migration on a PR branch was **resequenced** after the cert preview branch (`jyezfiehhfgnvhzzffxr`) already applied the earlier timestamp, Supabase Preview fails with `Remote migration versions not found in local migrations directory`.

The canonical fix is a **no-op ledger compatibility stub** at the earlier version (listed in `supabase/preview-migration-ledger-compat.txt`) plus the forward migration at the new timestamp. Preview branches that already applied the patch under the old version reconcile without re-running destructive DDL; fresh clean replays apply the forward patch only.

## Stage-1B certification

After sync, confirm readiness by running the in-preview cert orchestrator (no VM preview DB/service-role required):

```bash
deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts
```

The preview cert runner probes `GEMINI_API_KEY` inside Edge Runtime before scoring fixtures. A missing secret yields `MISSING_CERT_EDGE_RUNTIME_SECRET:GEMINI_API_KEY`.

## Owner one-time setup checklist

1. Add GitHub repository secret `GEMINI_API_KEY` (Oasis runtime Gemini credential; same provider key used for production worker path).
2. Ensure repository secrets `SUPABASE_ACCESS_TOKEN` and `GEMINI_API_KEY` are configured (production Edge credentials remain in the production Supabase project separately).
3. Run the sync workflow for the active cert preview ref, **or** complete dotenvx encrypted `.env.preview` bootstrap above.
4. Rerun Stage-1B: `deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts`.
