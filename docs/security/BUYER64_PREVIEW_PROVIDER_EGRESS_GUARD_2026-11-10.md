# Buyer #64 / Core #520 — Preview provider-egress guard (source-only candidate)

Status: **UNMERGED / UNDEPLOYED / UNREVIEWED — NOT A UAT CERTIFICATION**  
Related: Core issue #520; Buyer issue #64; Core PR #519.

## Threat model and trust boundary

Existing paid GitHub-linked Core #519 Preview `stkvyotdkysieuvpuues` runs 39 Edge Functions. Three inherited WhatsApp cron jobs are currently disabled, but direct function invocation, queued work, webhooks and provider credentials can still lead to external sends. Never infer network isolation from empty pg_net or disabled cron.

The shared `providerEgressGate.ts` requires both hosted Supabase-managed runtime signals to match canonical production before granting outbound provider calls:

- `SUPABASE_URL` must be the **exact** production API URL.
- `DENO_DEPLOYMENT_ID` must be shaped as production project ref, deployed function UUID and positive version (per Supabase hosted Edge runtime documentation).

A request header, test flag, recipient, JWT role, service-role client or provider key is **not** a substitute. Missing/malformed identity, local development, a preview project URL and mixed production/preview signals fail closed. No sandbox sending is enabled. The guard does not change server-level network access, remote secrets or Supabase project settings.

Sources: https://supabase.com/docs/guides/functions/secrets and https://supabase.com/docs/guides/functions/auth.

## Scope of this candidate branch

- `notify-event`: denies preview POST before staff/DB operations and wraps all three Resend/Click2API/MSG91 HTTP sends.
- `whatsapp-operator-reply-consumer` and `whatsapp-packet-ai-consumer`: deny preview direct requests before creating the service-role client, claiming queue work or AI processing.
- `whatsappOperatorReplyDispatch`: denies previews before lease claims or provider-status mutations, with guarded last-hop Click2API fetch.
- Regression tests: negative local/preview/mixed runtime identity, zero outbound calls with synthetic credentials, fake production fetch only, source-guard placement and zero queue RPCs.
- Edge governance and WhatsApp reply workflow register tests. No runtime/provider network is authorized for the new guard tests.

**Coverage is deliberately incomplete.** Do not treat this branch as a general firewall or sufficient isolation of the other deployed Edge Functions. Core's `geminiProvider`, `whatsapp-webhook`, AI gateway, and Central-origin legacy functions `msg91-otp`, `whatsapp-otp`, `send-email`, `send-whatsapp` still require separately audited guarded call sites. The latter two have source/runtime mismatches; never blindly redeploy Central's copies into Core.

## Required protected release before any Preview use

1. Confirm exact Git branch head and diff against current protected main. Run Deno formatting/lint/typecheck, full existing governance, new no-network tests and independent CodeRabbit/Cursor/security review. The GitHub branch alone has not executed hosted CI.
2. Obtain owner and CODEOWNER approval. Do not weaken mandatory checks or rulesets to merge.
3. Independently attest `DENO_DEPLOYMENT_ID` availability and exact format on *existing* production runtime **without sending to providers or reading secrets**; mismatch is a production regression and blocks deployment.
4. Resolve missing call-site coverage and backend source ownership across Central and Core, including all 39 currently deployed functions. Prove zero external sends in preview through negative tests for webhooks, credentialed handlers, staff/service-role callers, Auth/queue paths and dynamic destinations.
5. Use an explicitly approved preview-only rollout with deployed bundle/source hashes, before/after function versions and rollback artifacts; preserve disabled WhatsApp schedules and read-only finance/address ACL checks. Do not auto-create additional billable branches.
6. Only after all gates pass: configure synthetic users/companies, run nonproduction GoTrue/quoted checkout tests, then EAS signed Android and MSG91 sandbox physical-device acceptance. Keep production and customer records untouched until separately authorized.

## Exact source-only evidence

A local Node v22 TypeScript-stripped test of an **exact git-blob-hash-matched copy** of the shared guard passed 16 assertions with injected no-network fetch. This is *not* Deno CI, a deployed Edge test or external-provider isolation proof.

**Decision: HOLD.** No protected merge, live provider send, checkout UAT or production migration authorized by this branch.
