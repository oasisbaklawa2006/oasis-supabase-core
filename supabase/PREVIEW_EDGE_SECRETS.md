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

### 3. CI verification and readiness (read-only)

The `provision-preview-dotenv` job in `.github/workflows/edge-function-governance.yml` is **strictly read-only**. It never generates, rotates or uploads the shared key, never writes to Git, holds no Supabase token, and never reads a key back from the Supabase Management API. It runs `scripts/verify-preview-dotenv-crypto-authority.sh`, which accepts exactly two authorities and otherwise fails closed (`KEY_CUSTODY_UNAVAILABLE`):

1. **Independently held key.** `PREVIEW_DOTENV_PRIVATE_KEY` (a protected GitHub secret that you hold outside Supabase). The key's derived public key must equal the `DOTENV_PUBLIC_KEY_PREVIEW` header **and** dotenvx must decrypt both entries with it. A supplied key that is wrong fails closed; it never falls through to an attestation.
2. **Narrow historical attestation** (only while no independent key is held). `scripts/verify-preview-dotenv-attestation.py` accepts the exact `supabase/.env.preview` blob only if it is listed in `supabase/.env.preview.attestations.json` **and** the GitHub API proves that a `Supabase Preview` check-run published by the trusted Supabase GitHub App (id 330661) completed with `success` on the attested commit, that `supabase/.env.preview` at that commit is that exact blob, and that `supabase/config.toml` at that commit declares both `env()` Edge Runtime secrets (so the hosted preview actually exercised the decryption). Any other ciphertext change fails closed. An attestation is not a waiver: hosted `Supabase Preview` and `Preview Edge Runtime readiness` still must pass at the PR head, and a skipped or not-applicable readiness check is not runtime certification. Adding or changing an attestation counts as a runtime-path change and therefore requires hosted readiness.

`Preview Edge Runtime readiness` runs only after the read-only verification succeeds.

### 4. Key maintenance (protected, manual, explicit)

`.github/workflows/sync-preview-cert-edge-secrets.yml` is the **only** workflow that may generate, rotate or upload `DOTENV_PRIVATE_KEY_PREVIEW`. It runs solely on `workflow_dispatch`, requires the exact phrase `AUTHORIZE-PREVIEW-DOTENVX-KEY-ROTATION` plus a change reference, and runs inside the protected `supabase-preview-key-authority` GitHub environment (configure required reviewers on that environment; the environment must not override `SUPABASE_ACCESS_TOKEN`). The key writer (`scripts/upload-production-dotenvx-key.py`) refuses pull-request contexts, refuses to run without `PREVIEW_KEY_ROTATION_AUTHORIZED=true`, and only ever targets the production project. The workflow re-publishes only an independently held key (`PREVIEW_DOTENV_PRIVATE_KEY`) that is proven to decrypt the committed `supabase/.env.preview`; it fails with `NEW_PREVIEW_DOTENVX_KEY_REQUIRES_PERSISTED_CIPHERTEXT` rather than generating and publishing a new key, because it cannot persist the matching ciphertext. Rotating to a new key overwrites a write-only secret and orphans every ciphertext encrypted to the previous key, so it is an owner-workstation procedure (section 2): record the new private key in the independent custody secret first, land the matching ciphertext on `main` in a reviewed PR, then re-publish the key with this workflow.

### 5. Credential tiers and owner setup (required before relying on this model)

Pull-request workflows can be edited by the PR author, so repository code alone cannot keep a repository-level secret away from them. The model is therefore credential tiering, enforced by the config gate:

| Credential | Where it lives | Who can read it |
|---|---|---|
| `SUPABASE_PREVIEW_READONLY_TOKEN` | repository secret | pull-request readiness job (`edge-function-governance.yml`) |
| `SUPABASE_ACCESS_TOKEN` (write-capable) | **environment** secrets only: `supabase-preview-key-authority`, `supabase-production`, `supabase-production-readonly` | only jobs that pass that environment's protection rules |
| `PREVIEW_DOTENV_PRIVATE_KEY` | repository secret (+ offline vault copy) | read-only verify job and the protected sync job |

No pull-request-triggered workflow may reference `secrets.SUPABASE_ACCESS_TOKEN` (gate-enforced), and the protected sync workflow runs only from `main`.

Important GitHub behaviours the setup must account for:

- A job that names a non-existent environment **creates it unprotected** (no reviewers, no secrets). Create and protect `supabase-preview-key-authority` **before** anything dispatches the sync workflow.
- A job in any environment can still read **repository** secrets, and an environment that does not define a secret falls back to the repository-level one. While a repository-level `SUPABASE_ACCESS_TOKEN` exists, any workflow, including a PR edit naming a brand-new environment, can obtain it without approval. Closing this requires deleting the repository-level copy (step 6 below).

Owner procedure (GitHub: Settings; Supabase: Account > Access Tokens). Do these in order; merge PR #415 only after step 4.

1. **Create/verify the environment.** Settings > Environments > New environment `supabase-preview-key-authority` (or open it if it exists). Enable *Required reviewers* (at least one person other than whoever dispatches), enable *Prevent self-review*, untick *Allow administrators to bypass configured protection rules*, and set *Deployment branches and tags* to *Selected branches and tags* with the single rule `main`.
2. **Mint a least-privilege PR token.** Supabase personal access tokens carry the full permissions of their account, so least privilege means a token from an account whose organisation role is *Read-only* (use a dedicated account/member; reusing the existing list-only token behind `supabase-production-readonly` is acceptable). If your plan has no Read-only role, no genuinely read-only token exists: keep the readiness job approval-gated instead (put it behind a reviewer-protected environment) and accept per-run approval.
3. **Add the PR token.** Settings > Secrets and variables > Actions > *New repository secret* named `SUPABASE_PREVIEW_READONLY_TOKEN`.
4. **Confirm the readiness job's needs.** The job lists and polls preview branches; with a read-only token it can no longer create one (`ensure-supabase-preview-branch.py` POSTs when no branch exists). Preview branches must then be created by the Supabase GitHub integration, which is the intended path. Do this before merge: until the secret exists, edge-runtime PRs fail closed with `SUPABASE_ACCESS_TOKEN is required`.
5. **Place write-capable tokens in environments.** Confirm each of `supabase-production`, `supabase-production-readonly` and `supabase-preview-key-authority` defines its own `SUPABASE_ACCESS_TOKEN` under *Environment secrets* (the production runbook already documents this for the first two). Add one to `supabase-preview-key-authority` if missing.
6. **Remove the repository-level write token.** Only after step 5 verifies the environments: Settings > Secrets and variables > Actions > delete the repository secret `SUPABASE_ACCESS_TOKEN`. Production release workflows are unaffected because their environments define their own copy; if one did not, the job would fail closed at its `test -n "$SUPABASE_ACCESS_TOKEN"` guard rather than run unauthenticated. If the old token may have been exposed to a PR workflow, revoke it in Supabase and issue a new one for the environments.
7. **Verify isolation (read-only, prints booleans only).** On a throwaway same-repository branch (delete it afterwards), open a PR containing a temporary workflow step `echo "write token visible: ${{ secrets.SUPABASE_ACCESS_TOKEN != '' }}"` and also one with `environment: supabase-preview-key-authority`: the first must print `false`; the second must pause for reviewer approval (reject it). Then dispatch `Sync Preview Cert Edge Secrets` from a non-`main` branch (the job must be skipped) and from `main` (it must wait for a reviewer; cancel unless a key run is intended).

## Governance

`scripts/check-preview-edge-runtime-secrets-config.sh` fails CI when:

- `[edge_runtime.secrets]` or required secret declarations are missing from `config.toml`
- The sync workflow or this document is removed
- The provision job writes Git, holds a Supabase token, or generates/uploads/reads back a key
- A workflow other than the protected sync workflow invokes the key generation/upload scripts
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

1. Add GitHub repository secret `GEMINI_API_KEY` (Oasis runtime Gemini credential; same provider key used for production worker path).
2. Add GitHub repository secret `WA_STAGE1B_CERT_SECRET` (strong random independent value for preview certification auth only).
3. Ensure repository secrets `GEMINI_API_KEY` and `WA_STAGE1B_CERT_SECRET` are configured. Pull-request workflows only need the least-privilege `SUPABASE_PREVIEW_READONLY_TOKEN` for the readiness job's preview-branch reads; the token that can write production secrets must live only in the protected environments (see section 5). Do not route dotenvx upload through `supabase-production-readonly` (list-only; HTTP 403 on upload).
4. Hold the private key for the committed `supabase/.env.preview` public key in repository secret `PREVIEW_DOTENV_PRIVATE_KEY` (and an offline vault copy). CI never generates, rotates or reads back this key; without it, only an exact-blob attestation can authorize the committed ciphertext.
5. Edge Function Governance is read-only: it verifies authority (section 3) and never materializes or uploads keys. To (re)publish the production-held key, an authorized owner dispatches `Sync Preview Cert Edge Secrets` with the authorization phrase and change reference (section 4).
6. Rerun Stage-1B: `deno run --allow-all scripts/whatsapp-stage1b-cert/run.ts`.
