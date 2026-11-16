# WA-100 legacy send-whatsapp: safe compatibility replacement — candidate

**No deployment authorized by this source candidate.** Live Core production `tcxvcatsqqertcnycuop` still hosts `send-whatsapp` v143 with verify_jwt=true, bundle SHA256 `8146d49a3711ca10e32c9f6979ea24bab497974e36f51417034863539d942ac9`.

## Production problem
The current live function can issue two Click2API sends and two MSG91 fallback sends for the same call. A timeout after external acceptance may therefore duplicate delivery across providers. It stores `delivered` in CRM/message tables on HTTP success before the signed/shared-token delivery callback. It logs customer phone and raw message data; its `interaction_type='whatsapp'` violates the production CRM timeline type CHECK (separate schema PR #544).

Current Central `src/utils/whatsapp.ts` invokes this function directly; `send-whatsapp-automation` is an additional server-side caller. **Therefore immediate tombstoning is unsafe.**

## Reviewed-source candidate
The replacement preserves the request and successful JSON response shapes, executes at most one Click2API HTTP POST, never uses MSG91 failover, returns `ACCEPTANCE_UNKNOWN` on transport uncertainty or identifier-free 2xx, and records `sent` rather than `delivered`. It strips phone/message contents from operational diagnostics and CRM text notes. No credential values are altered. Provider-auth header choice still requires Click2API confirmation.

## Mandatory release conditions
1. Resolve and independently approve Core #542 first; `wamid` extraction must be consistent with the governed sender.
2. Independently approve and apply #544's CRM timeline schema migration in a protected production release, with pgTAP. Do not deploy a sender that silently fails CRM timeline inserts.
3. Complete a caller inventory and durable per-command idempotency contract. **The single-attempt adapter does not stop duplicate sends caused by independent UI/API retries**. Do not deploy it as a complete duplicate-prevention solution until this is mitigated/explicitly managed.
4. Preserve the active Central call contract and order workflow; certify manual, order and automation callers in isolated Preview, including unknown-acceptance terminal semantics. `send-whatsapp-automation` currently inserts `contact_id=null` into a NOT NULL `whatsapp_automations.contact_id` column, a separate failure that must be fixed before automation certification.
5. Compare deployed v143 bundle and source closure to pinned baseline. Capture complete private recovery archive, attest reviewed code, secure independent CODEOWNER review, and release only the named function through protected `supabase-production` approval.
6. After protected deploy: read back correct source/JWT/version and verify provider acknowledgement vs delivered/read truth; one consented Core send with a unique idempotency key. No legacy `FAILED_FINAL` or `QUARANTINED` replay.

## Explicit non-goals
This does not establish Click2API credential validity, the provider queue UUID to Meta wamid mapping, CTA domain liveness, external callback HMAC for Click2API, or end-to-end delivery proof. No live sends or production changes have been made.

## Default-off sender guard (November 2026)

The candidate now refuses all outbound provider calls unless the separate server-only environment variable `WA100_LEGACY_SENDER_SEND_ENABLED` is **exactly** `true`. Missing, blank and other values fail closed with HTTP 503 and `WA100_SENDER_RELEASE_NOT_AUTHORIZED`. Never set or copy this switch into a public client; do not enable it without independently reviewed Central/API idempotency, provider credential, consent/template, and protected deployment evidence.

Passing CI or deploying to an isolated preview does **not** authorize enabling this switch. Keep it unset in every environment until explicit owner release approval, and verify refusal without making a provider request before controlled UAT. The `send-whatsapp` function must retain `verify_jwt=true`.
