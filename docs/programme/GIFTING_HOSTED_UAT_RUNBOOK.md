# Gifting enquiry receiver — hosted synthetic UAT runbook

Prepared for execution in an **authorised environment** (GitHub Actions with a protected environment). It has **not been
executed**: the agent session that prepared it cannot reach the preview's function host (network policy), and no result of
this procedure exists yet. Local runs (below) validate the runner's logic, not the hosted deployment.

## What it proves, and what it does not
Proves, against the **identified isolated preview branch only**: the deployed `gifting-enquiries` Edge Function and its
database receiver accept, replay, reject and deduplicate synthetic enquiries over real HTTPS; bad credentials never write;
marketing-only submissions never enter the queue; test credentials are revoked afterwards.
Does **not** prove: the Gifting website's server-side sender with a real preview token, the Vercel Preview environment
binding, any production behaviour, or Central staff-queue behaviour. Those remain separate acceptance steps.

## Safety design
| Control | How |
|---|---|
| Manual only | `workflow_dispatch`; the job also needs the typed phrase `RUN-SYNTHETIC-UAT` |
| One reviewed target | the ref must be in `docs/programme/gifting-uat-targets.json` (non-persistent, data-free); the production ref is on a deny list that wins even if someone allow-lists it |
| Credential tied to the target | the database URL must be exactly `db.<ref>.supabase.co`, or a pooler whose exact host is listed in the target's `pooler_hosts` with a `postgres.<ref>` user; anything else aborts before any database call |
| Function URL derived, not supplied | `https://<ref>.supabase.co/functions/v1/gifting-enquiries` |
| Isolation preflight, read-only | receiver migration recorded; `gifting_enquiries` exists; `products` empty; no non-UAT consumers or enquiries; `anon` cannot execute the receiver RPC. Any failure aborts before a write |
| Scoped short-lived secrets | one secret, `GIFTING_UAT_DB_URL`, for the preview branch database only, in the protected `gifting-preview-uat` environment; the token that exercises the HTTP receiver is created inside the database, lives 30 minutes, write-only, bound to a dedicated synthetic consumer |
| Redaction | tokens are masked in logs, kept in memory, never written to disk; evidence is written only after a scan finds no token pattern or known secret |
| Cleanup | in a `finally`: revoke every token, suspend the consumer, count live tokens (must be 0), then prove the valid token now gets 401 |
| Least privilege | workflow token is `contents: read`; no secret inheritance; PR triggers are impossible (the repository secrets guard and this runner's regression test enforce it) |

## One-time owner prerequisites
1. In the Core repository settings create the **environment `gifting-preview-uat`** with at least one required reviewer who
   is not the dispatcher.
2. Add the environment secret **`GIFTING_UAT_DB_URL`**: the connection string of the preview branch database
   (Supabase dashboard → the preview branch → Database settings; `postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres`
   or, only if its exact host was reviewed and listed in `pooler_hosts` in `gifting-uat-targets.json`, the pooler form `postgres.<ref>`). Use a credential for **that branch only**. Never paste it in an issue or chat.
3. Confirm the branch still exists and is healthy. Preview branches live only while Core PR #557 exists; if it was recreated,
   its ref changed and the allow-list entry must be updated in a reviewed PR first.

## Run
Actions → "Gifting Receiver Hosted UAT" → Run workflow: `preview_ref` = the allow-listed ref, `confirm` = `RUN-SYNTHETIC-UAT`.
Approve the environment gate when prompted. The job takes about two minutes.

## Expected result
24 scenarios, all PASS, `cleanup_verified: true`, exit code 0:
- credentials: missing / invalid / expired / revoked → 401, wrong scope → 403, no row written;
- first delivery 201 with one row; identical replay 200 with the **same** `enquiryId`; conflicting payload 409 with the stored
  enquiry unchanged; exact replay still succeeds afterwards;
- 20 simultaneous deliveries of one lead → all accepted, exactly one row, one `enquiryId`;
- `newsletter` / `rewards` → 422 and no row; bad idempotency key 400; invalid JSON 400; wrong media type 415; GET 405;
- cleanup: 0 live tokens, consumer suspended, the valid token rejected after revocation.

Evidence: the artifact `gifting-receiver-hosted-uat-<run id>` (`evidence.json`, `evidence.md`), retained 30 days. It contains
scenario names, observed HTTP statuses and row counts, the target ref and the commit SHA. It contains no credential.

## If it fails
- **Exit 2 "UAT ABORTED"**: a safety check refused the run **before provisioning**, so nothing was written. The message names the
  failed guard (wrong ref, foreign credential, not an empty preview, migration missing). Fix the cause; do not weaken the guard.
- **Exit 1 with a `run: execution failed after provisioning` row**: a database or network error happened after the temporary
  consumer and tokens were created, so **writes may exist**. Cleanup still ran and the scanned evidence was still written; read
  `cleanup_verified` in `evidence.json`. If it is not `true`, revoke the consumer manually (below) **before** re-running.
- **Exit 1 with a FAIL row**: a scenario failed. Cleanup still ran. Attach `evidence.md` to the Core PR and treat the receiver
  as not accepted.
- **Exit 1 "UAT FAILED AFTER PROVISIONING … evidence withheld"**: the redaction scan blocked the evidence, so no
  `evidence.*` files exist. Rows were written. Read `cleanup verified: true|false` on the stderr line; to check cleanup by hand:
  `select count(*) from public.connect_tokens where revoked_at is null and consumer_id in (select id from public.connect_consumers where consumer_key like 'gifting-uat-hosted-%');`
  must return 0 and the consumer must be suspended. Treat the run as failed, do not attach evidence, then rotate `GIFTING_UAT_DB_URL`.
- **"cleanup: revocation failed"**: revoke the consumer manually in the preview branch:
  `update public.connect_tokens set revoked_at = now() where consumer_id in (select id from public.connect_consumers where consumer_key like 'gifting-uat-hosted-%');`
  then rotate `GIFTING_UAT_DB_URL`.

## After the run
Remove or rotate `GIFTING_UAT_DB_URL` (the preview branch is temporary anyway). Link the evidence on Gifting PR #37 and
Central #677. Synthetic rows (`source = uat-hosted-synthetic`) and a suspended consumer remain on the preview branch by design
and disappear with it.

## Validating the runner locally (not hosted acceptance)
`python3` and `psql` are required. With a scratch PostgreSQL that has the CONNECT-2 and receiver migrations and a local TLS
server running the real handler:
```
GIFTING_UAT_LOCAL_TEST=1 GIFTING_UAT_DB_URL=postgresql://postgres@127.0.0.1:5544/<db> \
  python3 scripts/uat/gifting-enquiry-receiver-hosted-uat.py --local-test --function-url https://127.0.0.1:8443/ \
  --ca-file cert.pem --evidence-dir uat-evidence
```
`--local-test` is refused inside GitHub Actions and without `GIFTING_UAT_LOCAL_TEST=1`. Result recorded when this runner was
prepared: 24/24 scenarios passed locally; the hosted run is outstanding.
`bash scripts/tests/verify-gifting-hosted-uat-runner.sh` runs the guard unit tests, the workflow contract checks and the
repository secrets guard against unsafe mutations.
