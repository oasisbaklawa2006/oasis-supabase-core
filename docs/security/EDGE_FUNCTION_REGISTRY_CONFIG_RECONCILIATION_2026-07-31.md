# Edge Function Registry and Configuration Reconciliation

Date: 2026-07-31  
Additive preview update: 2026-08-17  
Procedure: 7 of 8  
Project: `tcxvcatsqqertcnycuop`

## Outcome

Repository registry and deployment configuration are reconciled for the current remediation baseline.

This is a repository-level reconciliation only. It does not assert that all 26 live production functions are safe, captured, deployable, or runtime-certified.

## Configuration baseline

`supabase/config.toml` declares five approved repository-managed functions for branch/preview deployment:

1. `catalogue-ai-copy` with `verify_jwt = true`.
2. `test-integration` with `verify_jwt = true`.
3. `whatsapp-content-interpret` with `verify_jwt = true`; this is a preview/staging-only, authenticated, read-only WhatsApp B2B multimodal interpretation helper pending physical certification and separate production activation approval.
4. `whatsapp-packet-ai-worker` with `verify_jwt = true`; this is a preview/staging-only trusted processor that additionally requires the service-role bearer contract in the function body. It may persist advisory packet interpretations and record governed media-processing outcomes, but has no live order, stock, payment, credit, delivery or customer-send authority.
5. `whatsapp-studio-inbox-bridge` with `verify_jwt = false` because it enforces `BRIDGE_CRON_SECRET` in the function body and remains disabled by default.

The following high-risk functions remain intentionally absent from preview configuration:

- `whatsapp-webhook` — production certification remains quarantined; controlled staging uses the capture-only implementation for physical certification.
- `generate-product-attributes` — repository implementation retired; live runtime retirement remains pending.

No broad production Edge Function deployment is permitted.

## Registry reconciliation

The authentication registry continues to account for all 26 live production functions.

`test-integration`, `whatsapp-content-interpret` and `whatsapp-packet-ai-worker` are repository-managed preview functions and therefore are not added to the 26-function live production inventory. The two WhatsApp AI functions must remain outside that live registry until separately approved production activation updates the inventory and runtime certification evidence.

Procedure outcomes reflected in the live registry remain:

- `generate-product-attributes`: repository tombstone present; repository closure complete; runtime removal pending.
- `whatsapp-webhook`: review complete; production certification failed; continued production quarantine required while controlled staging certification proceeds.
- `whatsapp-studio-inbox-bridge`: repository-certified for controlled manual execution only.
- All uncaptured legacy functions remain explicitly pending rather than being silently classified as safe.

## B2B multimodal interpreter preview contract — 2026-08-17

`whatsapp-content-interpret` accepts a chronological packet of authoritative inbound provider message identifiers and re-loads every message under the caller's RLS scope. `whatsapp-packet-ai-worker` is the trusted server-side packet processor: it loads the stitched packet, performs the same governed multimodal reasoning, validates provenance, persists an append-only advisory interpretation, and records successful media-processing outcomes through trusted Core RPC authority. The preview contract covers:

- English, Hindi/Devanagari and Roman Hinglish text, including mistyping, misspelling, phonetic spelling and abbreviations;
- photographs, screenshots and handwriting;
- voice/audio transcription;
- video evidence;
- PDF documents and purchase orders;
- cross-fragment corrections and packet-level AI conclusions.

The output is derived advisory evidence only: normalized/extracted text, language/confidence/warnings, intent, explicit facts with provider-message provenance, candidate order lines, corrections, ambiguities and a recommended human action. It has no order creation/promotion, stock reservation, payment/credit approval, disclosure or customer-send authority. Final commercial decisions remain human/authority governed.

Repository governance locks both WhatsApp AI functions to the canonical Lovable AI Gateway contract:

- `https://ai.gateway.lovable.dev/v1/chat/completions`;
- `https://ai.gateway.lovable.dev/v1/audio/transcriptions`;
- `Lovable-API-Key` credential header;
- `google/gemini-3.6-flash` for multimodal packet reasoning;
- `openai/gpt-4o-mini-transcribe` for voice transcription;
- no OpenRouter use with the Lovable credential.

## Source reconciliation alignment

The source reconciliation inventory remains authoritative for production canonical-source presence:

- The prior production reconciliation baseline remains unchanged.
- `whatsapp-content-interpret` and `whatsapp-packet-ai-worker` are additional repository sources for preview/staging certification only and must not be counted as live production functions until approved activation.
- Registry closure status must not be interpreted as production runtime certification.

## Invariants

The following conditions are mandatory:

- Every live production function remains represented in the authentication registry.
- Every production function declared in `supabase/config.toml` must match the live registry.
- Repository-managed preview-only functions may remain outside the live registry only when their source is present, their authentication mode is checked directly, and production activation is explicitly prohibited until certification.
- JWT modes in config must match the applicable registry or preview-only contract.
- `whatsapp-content-interpret` must remain `verify_jwt = true` and preview-only until the complete B2B multimodal physical gate passes and production activation is separately approved.
- `whatsapp-packet-ai-worker` must remain `verify_jwt = true`, service-role body-authorized and preview-only until the same gate passes and production activation is separately approved.
- `whatsapp-webhook` and `generate-product-attributes` must not be preview-declared.
- Failed, retired, quarantined, partial, pending, preview-only and repository-certified outcomes must remain distinguishable.
- Procedure 8 is the only phase permitted to record runtime certification or production activation evidence.

## Final disposition

Procedure 7 is complete at repository level.

Production deployment, live secret validation, provider callback verification, controlled bridge dry runs and runtime sign-off remain exclusively within Procedure 8. The 2026-08-17 WhatsApp AI staging/preview activation does not constitute production activation.