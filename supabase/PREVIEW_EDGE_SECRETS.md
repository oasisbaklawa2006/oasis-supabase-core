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

3. On each preview branch deploy, the branching executor decrypts `.env.preview` using `DOTENV_PRIVATE_KEY_PREVIEW` stored on production (`tcxvcatsqqertcnycuop`) and injects Edge Runtime secrets into the current PR preview sub-cloud. That production secret is **write-only**: the Supabase Management API returns no stored value (only a digest), so nothing read back from it is ever a usable or verifiable private key.

### 3. CI verification and readiness (unprivileged)

Pull-request workflows run code the PR author controls, so they hold **no** Supabase Management API token, **no** dotenvx private key and **no** production secret. They receive only the read-only `github.token` and the preview cert-runner probe secret `WA_STAGE1B_CERT_SECRET`.

For a runtime-scoped PR (it touches `supabase/.env.preview`, `config.toml` or another preview launch path):

1. `provision-preview-dotenv` (check name kept because Core merge governance requires it) runs `scripts/check-preview-hosted-proof-preconditions.sh`, offline and credential-free. A hosted success only proves the ciphertext decrypts if `config.toml` declares both `env()` Edge Runtime secrets and `.env.preview` holds *encrypted* values for them, so both are required, and no private key may be committed.
2. `Preview Edge Runtime readiness` waits for the trusted Supabase GitHub App's (id 330661) `Supabase Preview` check-run on the exact PR head, using `scripts/wait-for-current-pr-preview-ref.sh`. That hosted run is Supabase's own executor decrypting the committed ciphertext with the production-held key, which is an independent cryptographic verification that does not depend on any key available to CI. Success yields the preview project ref (from the check-run's `details_url`; the production ref is rejected).
3. The readiness probe then calls the preview Edge Runtime with `WA_STAGE1B_CERT_SECRET` and requires `GEMINI_API_KEY_EDGE_RUNTIME: true`.

Fail-closed behaviour: a skipped (for example the concurrent preview-branch limit), failed, cancelled, pending, missing or untrusted hosted check never passes, and the job never creates, rebases or resets a preview branch. If the Supabase integration does not provision a preview, a runtime-scoped PR is **BLOCKED** (`PREVIEW_NOT_PROVISIONED`) until the owner frees a preview slot. A static-only PR reports `Preview Edge Runtime readiness not applicable`; that is not runtime certification.

There is no attestation, readback or key-custody check in the PR path: arbitrary ciphertext cannot pass because only the hosted executor holding the real key can produce the required `success`.

### 4. Key maintenance (protected, manual, explicit)

`.github/workflows/sync-preview-cert-edge-secrets.yml` is the **only** workflow that may verify the private key or generate, rotate or upload `DOTENV_PRIVATE_KEY_PREVIEW`. It runs solely on `workflow_dispatch` from `main`, requires the exact phrase `AUTHORIZE-PREVIEW-DOTENVX-KEY-ROTATION` plus a change reference, and runs inside the protected `supabase-preview-key-authority` GitHub environment. The key writer (`scripts/upload-production-dotenvx-key.py`) refuses pull-request contexts, refuses to run without `PREVIEW_KEY_ROTATION_AUTHORIZED=true`, and only ever targets the production project.

Before anything is published, `scripts/verify-preview-dotenv-crypto-authority.sh` requires the independently held `PREVIEW_DOTENV_PRIVATE_KEY` (an *environment* secret) to derive the committed `DOTENV_PUBLIC_KEY_PREVIEW` and decrypt both entries; there is no fallback. The workflow then re-publishes only that key and fails with `NEW_PREVIEW_DOTENVX_KEY_REQUIRES_PERSISTED_CIPHERTEXT` rather than generating a new one, because it cannot persist the matching ciphertext. Rotating to a new key overwrites a write-only secret and orphans every ciphertext encrypted to the previous key, so it is an owner-workstation procedure (section 2): record the new private key as an environment secret first, land the matching ciphertext on `main` in a reviewed PR, then re-publish the key with this workflow.

### 5. Credential architecture and owner setup

| Credential | Where it lives | Who can read it |
|---|---|---|
| `github.token` (read-only), `WA_STAGE1B_CERT_SECRET` | repository | pull-request workflows (the cert secret authorises only the preview cert-runner probe) |
| `SUPABASE_ACCESS_TOKEN`, `PREVIEW_DOTENV_PRIVATE_KEY`, `GEMINI_API_KEY` for preview key maintenance | **environment** secrets of `supabase-preview-key-authority` | only the dispatched sync job, after reviewer approval, from `main` |
| `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_URL`, ... for production releases | environment secrets of `supabase-production` / `supabase-production-readonly` | only those protected release jobs |

No repository-level `SUPABASE_ACCESS_TOKEN` is needed by any workflow, and no Supabase read-only account or token is needed: pull-request workflows use no Supabase credential at all. The config gate (`check-preview-edge-runtime-secrets-config.sh`) enforces, for every workflow: privileged secrets (`SUPABASE_*`, `*ACCESS_TOKEN`, `*DB_URL`, `*SERVICE_ROLE`, `PREVIEW_DOTENV*`, `GEMINI_API_KEY`) may be referenced only by jobs bound to a protected environment; pull-request workflows may reference only `WA_STAGE1B_CERT_SECRET` and may not bind an environment or invoke privileged Supabase/key scripts; no `pull_request_target`, reusable workflow, `secrets: inherit` or dynamic secret access; `workflow_run` workflows reference no secrets.

GitHub behaviours that make repository-level secrets the real exposure:

- A pull request can edit any workflow file, so a repository-level secret is readable by PR-controlled code regardless of what existing workflows reference.
- An environment-bound job can still read **repository** secrets, and an environment that does not define a secret falls back to the repository-level one.
- A job naming a missing environment **creates it unprotected**. The in-repo gate is review-enforced; the enforced boundary is that privileged secrets exist **only** as environment secrets of environments restricted to reviewers and `main`.

Owner steps (all GitHub UI; no new Supabase account is required):

1. **Environment** `supabase-preview-key-authority`: Settings > Environments. Required reviewer set, *Prevent self-review* on, *Allow administrators to bypass* off, *Deployment branches and tags* = `main` only. (Confirm these persisted by reopening the environment page.)
2. **Add environment secrets to `supabase-preview-key-authority`** (Environment secrets, not repository secrets): `SUPABASE_ACCESS_TOKEN` (a token able to set secrets on the production project), `GEMINI_API_KEY` and, once independent custody exists, `PREVIEW_DOTENV_PRIVATE_KEY`.
3. **Verify the production environments** `supabase-production` and `supabase-production-readonly` each list their own `SUPABASE_ACCESS_TOKEN` under *Environment secrets* (the production runbook documents this). Do not edit them.
4. **Delete the repository-level secrets** `SUPABASE_ACCESS_TOKEN`, `PREVIEW_DOTENV_PRIVATE_KEY` and `GEMINI_API_KEY` (Settings > Secrets and variables > Actions > Repository secrets). Do this only after steps 2 and 3. Keep `WA_STAGE1B_CERT_SECRET` at repository level: the PR readiness probe needs it. Removing the repository `SUPABASE_ACCESS_TOKEN` cannot break production release workflows, which read their environment copies; a missing copy would fail closed at their existing `test -n "$SUPABASE_ACCESS_TOKEN"` guards.
5. **Decide on rotation.** The old repository-level token and `GEMINI_API_KEY` were readable by pull-request-controlled workflows. If any untrusted or unreviewed PR could have run, revoke them at Supabase / the Gemini console and issue new values for the environments (this repository's automation never rotates secrets).
6. **Preview slots.** Runtime-scoped PRs now depend on the Supabase integration provisioning a preview branch. If `Supabase Preview` shows *skipped* for a PR (concurrent preview-branch limit), raise the limit or delete stale preview branches in the Supabase dashboard; otherwise runtime readiness stays BLOCKED by design.
7. **Verify isolation (booleans only).** On a throwaway same-repository branch, a PR whose temporary step is `echo "token visible: ${{ secrets.SUPABASE_ACCESS_TOKEN != '' }}"` must print `false`; the same step with `environment: supabase-preview-key-authority` must wait for reviewer approval (reject it). Dispatching `Sync Preview Cert Edge Secrets` from a non-`main` branch must be skipped. Delete the branch afterwards.

## Governance

`scripts/check-preview-edge-runtime-secrets-config.sh` fails CI when:

- `[edge_runtime.secrets]` or required secret declarations are missing from `config.toml`
- The sync workflow or this document is removed
- A pull-request workflow receives a privileged Supabase secret, a dotenvx private key or any secret other than the cert probe secret, binds an environment, or invokes Management API / key scripts
- A privileged secret is referenced outside a protected-environment job, or `pull_request_target`, reusable workflows or `secrets: inherit` appear
- The readiness job gains a Management API credential, a branch-creation path or a Git write
- A workflow other than the protected sync workflow invokes the key verification/generation/upload scripts
- The Management API private-key readback script reappears
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

1. Secrets for preview key maintenance (`SUPABASE_ACCESS_TOKEN`, `GEMINI_API_KEY`, `PREVIEW_DOTENV_PRIVATE_KEY`) are **environment** secrets of `supabase-preview-key-authority`; the repository-level copies are deleted (section 5, steps 2-4).
2. Repository secret `WA_STAGE1B_CERT_SECRET` (strong random independent value for preview certification auth only) is the only secret pull-request workflows may use.
3. Pull-request governance is unprivileged and never materializes, uploads or verifies keys. To (re)publish the production-held key, an authorized owner dispatches `Sync Preview Cert Edge Secrets` from `main` with the authorization phrase and change reference (section 4).
4. Rerun Stage-1B: `deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts`.
