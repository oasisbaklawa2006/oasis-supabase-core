# WhatsApp packet AI: large media packets (WA-RECOVERY-02)

Scope: `supabase/functions/whatsapp-packet-ai-worker` (Edge only; no schema change, no migration).

## What was wrong

Job `8803fe46-373d-49dc-aad1-19bf8ba02daa` (packet `55f8c388-...`, 18 inbound images, 2026-09-22) fails with
`INTERPRETATION_PACKET_TOO_LARGE` on every attempt (about 5,000 so far) because the worker capped a packet at
16 messages. Raising the cap alone is not a repair, and it does not recover this job:

- Read-only production check (2026-10-22): all 18 `media_url` values are Meta `lookaside.fbsbx.com` links whose
  `ext` expiry was **2026-09-22 06:41-06:45 UTC**, about five minutes after receipt. They are long expired.
- No copy exists: `storage.objects` has no object for the packet, `whatsapp_media_processing_events` has no rows,
  and `whatsapp_inbound_messages` keeps only the raw webhook payload.
- So the historical images cannot be fetched by the worker. With the cap raised, that job fails on missing media
  instead of on size. **Recovery of that job is a human decision (quarantine, then ask the sender to resend),
  not a code path.** See `WHATSAPP_HISTORICAL_DISPATCH_JOB_RECOVERY.md`.

## What this change does

1. Message ceiling raised from 16 to 32 for the packet and case-context loaders. A single
   `assertPacketMessageCount()` now enforces it; above 32 the existing deterministic
   `INTERPRETATION_PACKET_TOO_LARGE` remains (bounded jobs dead-letter it on first occurrence).
2. **Completeness**: for packets above 16 messages, every media item must be retrieved before Gemini is called.
   Otherwise the worker raises `OVERSIZED_PACKET_MEDIA_INCOMPLETE:missing=N/M reasons=...`. No interpretation is
   persisted, no media is marked complete, and nothing is silently omitted.
3. **Aggregate size**: for packets above 16 messages, exceeding the 24 MiB aggregate budget now raises the
   deterministic `PACKET_MEDIA_TOO_LARGE` (human review) instead of silently dropping the tail. Packets of 16 or
   fewer keep their existing best-effort behaviour (the failure is an explicit warning and the model is told the
   evidence was unreadable).
4. **Time box**: the sequential media phase is capped at 25 s, and each fetch is capped at the time remaining.
   The dispatch lease is 120 s and one Gemini call can take up to 90 s, so a slow provider can no longer push a
   packet past its lease (which would waste a paid call and be rejected by lease fencing).
   `downloadGovernedWhatsAppMedia()` gains an optional timeout argument; the default and ceiling stay 20 s.

Unchanged by design: lease and fencing semantics, packet-revision handling, fingerprint idempotency, media
completion sequencing (only successfully attached ids are completed), human-review authority, and all SQL.

## Why not chunking

Chunking would need a merge step across several model calls and a new interpretation contract, and the evidence
shows size is not the failure mode: compressed WhatsApp photos are far below the 24 MiB budget, and the one
historical case fails on expiry, not size. If real traffic ever exceeds 32 messages or the aggregate budget, those
packets fail closed into human review with all messages preserved. Revisit if that happens in practice.

## Evidence-accounting details

- Completeness counts occurrences, not distinct ids: provider-id uniqueness is per provider, so a successful fetch
  of one message cannot vouch for a failed message that shares its id.
- A packet above 16 messages with a blank or missing `provider_message_id` is rejected (`PACKET_MESSAGE_ID_MISSING`)
  before the row is dropped. Production today has 0 such rows among 693 inbound packet messages.
- The case-context RPC (`whatsapp_case_context_messages`) already removes blank-id rows server-side, so the worker
  cannot see them on that path. Closing that needs a SQL change and is not part of this PR (0 occurrences today).

## Known limits

- Gemini inline-data limits: Google's announcement raised the inline payload ceiling from 20 MB to 100 MB
  (base64) with per-type variation; older guidance still says 20 MB. The 24 MiB raw budget (about 32 MiB base64)
  is within the newer figure only. Confirm against current Gemini docs before relying on a packet near the budget.
- Provider media links expire within minutes. Any packet that waits longer than that for a worker (queue backlog,
  outage, lease loop) cannot be interpreted. Fetching media at ingest into storage is the durable fix; it needs a
  storage and schema decision and is out of scope here.
- Timing figures above are code constants, not measurements of the live function.

## Behavioural tests

`supabase/functions/whatsapp-packet-ai-worker/index.test.ts` (Deno, injected downloader and clock): 1/16/17/18/32
image packets (all images attached once, original order), 33 rejected, captions kept, missing first/middle/last
image, expired URLs, unsupported/oversized/unreachable/timed-out media, missing URL, legacy <=16 semantics,
aggregate overflow, the 25 s time box, deterministic replay, duplicate completion ids, text-only 32-message packet.
Mutation checks confirm that removing the completeness assertion, the time box, the aggregate rethrow, or raising the
ceiling each fails at least one test.

These tests do not exercise live Gemini or WhatsApp. Lease expiry, concurrent workers, retry exhaustion, dead-letter,
requeue, ambiguous identity and multiple potential orders are covered by the existing pgTAP suites for
`20261022120000` and `20261022121000` and the two-session race script, not re-implemented here.

## Release and rollback

Edge-only. A migration is not involved.

1. Merge the PR (approval required).
2. The worker's production release workflow (`whatsapp-packet-ai-worker-production-release.yml`) pins the reviewed
   source closure (`REVIEWED_SOURCE_CLOSURE_SHA256`), the reviewed release SHA and the expected live version.
   **Main's worker closure already differs from the pinned value, and this change moves it again**, so the pins
   must be updated in a reviewed change before a deploy can pass its certification step. This is a prerequisite,
   not something this PR does.
3. Run the workflow first with `deploy=false` (read-only preflight), then `deploy=true` with the exact release SHA
   in the protected `supabase-production` environment.
4. Verify with `certify_existing=true`, then watch `whatsapp_packet_ai_dispatch_exceptions_v` and
   `last_error_code` for `OVERSIZED_PACKET_MEDIA_INCOMPLETE` and `PACKET_MEDIA_TOO_LARGE`.

Rollback: redeploy the previous reviewed worker version through the same workflow (the previous version is the
current live one). No data migration is needed; jobs in flight are retried by the existing budget.
