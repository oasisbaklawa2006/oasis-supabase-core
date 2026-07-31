# Edge Function Runtime Certification — 2026-07-31

## Procedure

Procedure 8 of 8: runtime certification and production sign-off.

## Current decision

**PRODUCTION SIGN-OFF WITHHELD.**

Repository controls are complete, but runtime certification cannot be granted without direct evidence from Supabase production project `tcxvcatsqqertcnycuop` and the relevant provider/runtime boundaries.

This record does not deploy, invoke, delete, enable, disable or reconfigure any production Edge Function.

## Required runtime evidence

### 1. Production inventory and source identity

- Export the current production Edge Function inventory, versions and JWT modes.
- Confirm the production inventory still contains 26 functions or explain every delta.
- Capture the deployed source hash or exact source bundle for each repository-managed function.
- Compare production source with the canonical repository source at the approved release commit.

### 2. `generate-product-attributes`

- Confirm whether production version 96 is still callable.
- Record a controlled request showing its current status and response shape.
- Replace or remove the live unsafe implementation only under an approved production change window.
- After the controlled change, prove that the endpoint is removed or returns the approved HTTP 410 tombstone.
- Confirm there are no active callers before final retirement.

### 3. `whatsapp-webhook`

- Do not deploy the repository source.
- Confirm current provider callback URL, provider ownership and live version.
- Verify handshake-token handling without disclosing token values.
- Verify POST authentication/signature controls and replay protection.
- Capture a successful provider callback and a rejected unauthenticated/replayed request.
- Confirm production message ingestion, deduplication and downstream processing remain intact.
- Certification remains failed until all mandatory authentication gates are evidenced.

### 4. `whatsapp-studio-inbox-bridge`

- Confirm `BRIDGE_CRON_SECRET` exists without exposing its value.
- Confirm `BRIDGE_ENABLED` is false before the first test.
- Invoke one authenticated dry run with a small explicit limit.
- Record rows read, preview result, cursor before/after and zero persistent changes.
- Enable non-dry-run processing only through a separately approved change.
- Run one small controlled batch, reconcile counts and inspect persisted bridge state.
- Do not enable recurring scheduling until the controlled batch is accepted.

### 5. Approved preview-managed functions

For `catalogue-ai-copy`, `test-integration` and `whatsapp-studio-inbox-bridge`:

- Confirm deployed JWT mode matches `supabase/config.toml`.
- Confirm repository source and production source are identical before release approval.
- Exercise unauthorized and authorized requests.
- Confirm no secret values are returned in logs or responses.

### 6. Integration verification

- Execute provider-specific connectivity tests where implemented.
- Treat credential presence as configuration evidence only, not health evidence.
- Record provider response status, timestamp and redacted correlation identifiers.
- Preserve `unverified` or `manual verification required` for integrations lacking a real connectivity test.

### 7. Observability and rollback

- Capture pre-change function versions and configuration.
- Establish a rollback target for each changed function.
- Review error logs and invocation metrics after each controlled action.
- Confirm no unexpected database writes, callback failures or duplicate processing.

## Sign-off rule

Production sign-off may be recorded only when all applicable evidence above is committed in a redacted runtime evidence record and reviewed. Missing evidence is a blocking result, not an implicit pass.

## Current procedure status

- Repository readiness: complete.
- Runtime execution: not performed in this tranche.
- Production deployment: not performed.
- Production certification: **blocked pending live evidence**.
- Overall remediation closure: **not complete**.
