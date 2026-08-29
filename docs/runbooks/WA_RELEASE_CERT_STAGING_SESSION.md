# WhatsApp Release Certification — Isolated Staging Session

This branch exists only to provision and certify the isolated Supabase preview used by the WhatsApp release-certification programme. It is not a feature-delivery branch and must not be merged merely to complete certification.

## Current authority

- Canonical Core main: `885e5ae0d940cef7e559ee910e0b8655ac1fd201`
- Stage-1 ingress repair: PR #128, squash merge `fab554fea099c7f8a3ea7f1aeb71af5fc5fd42b6`
- Stage-1B noncommercial media-completion repair: PR #134, squash merge `14928687fe86c253f3d070e3bc06a9e9577589b4`
- Certification branch: `cert/wa-release-cert`
- Certification PR: `#126`
- Isolated Supabase preview project: `dfjslkwxawnzurolifpm`
- Production project: `tcxvcatsqqertcnycuop`
- Preview was provisioned with `with_data=false`; production/customer data must never be copied into it.

The certification branch name is **not** sufficient release evidence. Every certification execution and every retained report must record the exact 40-character certification head that was executed. If the branch moves, previous evidence remains attached to its previous SHA and must not be represented as evidence for the new head.

## Universal production-target prohibition

Every component used in this certification session must target the isolated preview and must hard-fail on production project ref `tcxvcatsqqertcnycuop`. This requirement applies to all of the following, not only CERT-A:

- Stage-1B media harnesses and fixture uploaders
- manual SQL clients and database scripts
- CERT-A and historical-corpus evaluation
- cross-repository E2E tests
- retry/concurrency/load/chaos runners
- Edge Function invocations and temporary certification probes
- provider callbacks, webhook tests and provider-side test configuration
- reconciliation and cleanup tools

Use `validateCertDatabaseTarget()` or an equivalent exact-ref fail-closed check wherever a database URL is accepted. An allowlist/opt-in is not permission to target production.

This certification session **cannot perform production database writes or production deployment**. If production migration is later separately and explicitly authorized, it must use `docs/runbooks/CONTROLLED_SUPABASE_PRODUCTION_RELEASE.md`, including protected-environment approval, exact commit checkout, migration-ledger re-check and serialized deployment. Certification evidence alone never authorizes production.

## Core refresh and merged repairs

### PR #128 — empty-body media ingress

PR #128 fixed premature `FAILED_INTERPRETATION` for empty-caption media. Pending media now remains nonterminal until media processing has an explicit outcome.

Required invariant:

**CAPTURED MEDIA ≠ FAILED INTERPRETATION**

Regression coverage includes pending media, explicit failure, recovery, replay idempotency and zero-loss reconciliation.

### PR #134 — noncommercial media completion

Stage 1B inspection found that `whatsapp-packet-ai-worker` could successfully interpret non-order media while `complete_whatsapp_media_processing` still failed with `WA4_EVIDENCE_NOT_FOUND` because noncommercial fan-out intentionally has no `whatsapp_commercial_evidence` row.

PR #134 fixes that path without weakening commercial authority:

- missing evidence is accepted only when authoritative inbound provenance contains JSON boolean `commercial_eligible: false`;
- commercial, missing, ambiguous or stringly typed provenance remains fail-closed;
- the trusted completion RPC is service-role only;
- commercial evidence remains immutable;
- append-only media events provide terminal authority;
- first terminal result wins and a later competing attempt cannot reverse it.

PR #134 was merged only after clean replay/pgTAP, migration governance, ownership checks, Codacy, CodeRabbit and independent collaborator approval.

## Stage 1B — actual multimodal worker certification

Stage 1B must use the **actual deployed `whatsapp-packet-ai-worker`**. Pre-built AI JSON, source inspection and pgTAP-only evidence do not constitute live media certification.

Current inference transport:

- worker → Lovable AI Gateway → `google/gemini-3.6-flash` for multimodal reasoning;
- audio → Lovable AI Gateway → `openai/gpt-4o-mini-transcribe`.

Lovable is only the current inference gateway. It may be replaced later under a separately certified provider abstraction; changing providers does not change Core commercial authority.

### Deployed preview runtime

Last verified cert-preview deployment:

- `whatsapp-webhook`: v154, post-#128 source
- `whatsapp-packet-ai-worker`: v13 ACTIVE
- `whatsapp-content-interpret`: v15 ACTIVE
- PR #134 migration/function contract present on `dfjslkwxawnzurolifpm`

Before any scored run, reverify versions/source provenance against the exact certification head. Do not rely on these version numbers after the branch moves.

### Runtime prerequisites

The deployed Edge runtime must have, without printing values:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `LOVABLE_API_KEY`
- `WHATSAPP_MEDIA_ALLOWED_HOSTS` including `dfjslkwxawnzurolifpm.supabase.co` when fixtures are served from cert-preview Storage

The Cloud Agent/harness process separately needs:

- `SUPABASE_SERVICE_ROLE_KEY` for `dfjslkwxawnzurolifpm`
- `DATABASE_URL`, **or** both `WA_CERT_ALLOW_REMOTE_DATABASE=true` and `WA_CERT_REMOTE_DATABASE_ALLOWLIST` matching the cert database host
- optional `SUPABASE_ACCESS_TOKEN` for deployment/version inspection
- optional Click2API credentials only when controlled provider-hosted fixtures are used
- optional `WA_STAGE1B_AUDIO_FIXTURE` for a sanitized spoken-audio fixture
- optional `WA_STAGE1B_DEVANAGARI_FONT` pointing to a local Devanagari-capable font; font binaries remain outside Git

`LOVABLE_API_KEY` belongs to the deployed cert Edge runtime. Installing the Lovable GitHub integration does not populate that runtime secret.

### Fixture integrity

Stage-1B media lives outside Git under `/tmp/wa-stage1b-cert-fixtures` by default and is uploaded only to synthetic cert-preview Storage.

The generator must fail closed rather than produce misleading evidence:

- audio must contain actual spoken order language; a tone is invalid;
- stale audio/video artifacts are removed before regeneration;
- the Hindi fixture must use a Devanagari-capable font with shaping support; missing-glyph output is invalid;
- optional video may be skipped if the environment cannot create a controlled supported fixture;
- no real customer media or PII is permitted.

### Required controlled cases

The frozen manifest covers printed orders, handwriting, exact visible labels, no-SKU products, quantity-only/no-quantity cases, image+caption, corrections, multi-image packets, catalogue screenshots, PO PDF, payment proof, complaint/damage, blurred/cropped/ambiguous media, fake price/discount/COD, prompt injection, Hindi, Hinglish, misspellings, spoken audio and optional video.

The controlled fixture set is **not** the historical 95% benchmark.

### Absolute authority expectations

- visual similarity alone never establishes exact SKU authority;
- quantity and UOM are never defaulted;
- sender is not automatically the customer;
- image-derived price, discount, COD, credit, payment terms, stock or delivery promises never override Core authority;
- a payment screenshot is not verified payment;
- complaint/damage media is not an order;
- prompt injection embedded in media cannot widen AI or Core authority;
- unreadable/ambiguous media fails closed with an accountable disposition.

The primary hard metric is:

**DANGEROUS AUTOMATED MEDIA FALSE POSITIVES = 0**

## Isolation and pre-run data audit

The original preview was created with `with_data=false`, but it now contains synthetic certification history from earlier smoke tests. Therefore a current run must not claim that all application tables are empty.

Before a scored run, audit every data-bearing WhatsApp/order table relevant to certification, including at minimum:

- `whatsapp_inbound_messages`
- `whatsapp_messages`
- `whatsapp_message_packets`
- `whatsapp_commercial_packets`
- `whatsapp_commercial_evidence`
- `whatsapp_media_processing_events`
- `whatsapp_packet_ai_dispatch_jobs`
- `whatsapp_packet_ai_interpretations`
- `whatsapp_communication_cases`
- `whatsapp_potential_orders`
- `whatsapp_order_autonomy_decisions`
- `sales_order_drafts`
- `orders`

The audit must distinguish the synthetic certification namespaces (`cert-*`, `wa-s1b-*` and the documented deterministic CERT fixtures) from anything else. If any non-cert/customer data is present, Stage 1B must stop. A final pristine benchmark may instead use a freshly rebuilt preview, but it must re-establish the same webhook/function provenance before testing.

The canonical `claim_next` worker proof must also start with no outstanding dispatch backlog capable of contaminating the run. The harness blocks rather than silently claiming another packet.

## Stage-1B report requirements

`artifacts/wa-stage1b-cert/report.json` must be written for both successful and failed/blocked executions and must retain partial completed fixture results after a runtime failure.

Report at minimum:

- exact certification SHA and Core authority SHA
- runtime version/provenance
- fixture and modality counts
- actual worker invocation count
- image intent/product/SKU/quantity/UOM metrics
- image-only straight-through rate for the controlled set
- controlled auto-action precision
- clarification correctness
- invented commercial leakage count
- dangerous automated media false positives
- duplicate draft/SO counts
- orphan/silent-loss/reconciliation results
- exact blocker when incomplete

No report may claim Stage 1 complete merely because the base 25-fixture recognition run passes.

## Required work after base recognition

### Image-derived clarification and resume

Prove quantity-only, UOM-only and product/SKU-specific clarification using actual reply correlation, context revision, `CASE_CONTEXT` dispatch, reevaluation and automatic continuation when fully resolved.

Also prove:

- `yes`, `ok`, `haan` do not fabricate a missing field;
- wrong sender does not resolve the case;
- answer-before-question fails closed;
- simultaneous answers do not corrupt authority;
- later explicit correction supersedes earlier evidence;
- no duplicate potential order, draft or SO is created.

### Replay and adversarial processing

Prove same provider-message replay ×10, same-media replay, same visual with different provider IDs, same visual from different senders, multi-image replay, concurrent claims, stale lease, stale packet revision, worker retry/crash, correction during interpretation and duplicate-promotion protection.

Required final invariants:

- duplicate draft = 0
- duplicate SO = 0
- cross-customer contamination = 0
- stale worker commit = 0
- silent media loss = 0
- dangerous automated media false positives = 0

### Final reconciliation

After all workers settle:

- orphan raw messages = 0
- packets without accountable disposition = 0
- duplicate commercial SO = 0
- `unaccounted_potential_orders = 0`
- unreadable/unsupported/corrupt media has an explicit disposition.

Only then may Stage 1 be marked complete and the protected historical corpus begin.

## Historical corpus boundary

The canonical Oasis B2B WhatsApp export remains protected outside Git. Raw exports and media are never committed. Only sanitized derived fixtures may enter the certification workspace. The historical 95% claim is measured later on a locked representative evaluation set, not on these synthetic Stage-1B fixtures.

## Remaining release route

1. Complete Stage 1 media certification.
2. Prepare protected historical corpus.
3. Run historical benchmark and governed learning loop.
4. Run cross-repository staging E2E.
5. Run chaos/load/reconciliation certification.
6. Run real non-production provider proof.
7. Produce final release ledger / GO-NO-GO classification.
8. Production canary only after separate explicit production authorization.

## Required teardown

When certification evidence is complete:

1. retain only approved sanitized reports/evidence;
2. revoke any temporary external provider credentials used for certification;
3. remove or restore any provider-side test webhook/callback configuration;
4. remove temporary cert-only Edge probes and cert-only runtime secrets that are no longer required;
5. delete/retire synthetic fixture storage as appropriate;
6. close PR #126 only after its evidence is no longer needed;
7. retire the preview branch unless it is deliberately retained for a future certification window.

Deleting a Supabase preview does not itself revoke credentials or configuration held by external providers, so external revocation is a mandatory teardown step.
