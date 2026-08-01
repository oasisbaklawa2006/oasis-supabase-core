# WhatsApp Click2API Runtime Evidence — 2026-08-02

## Live evidence observed

A controlled inbound message (`Test 1`) was sent to the Oasis Baklawa business number through the configured Click2API channel.

Observed production behavior before hardening:

- inbound Meta-shaped message payload reached `whatsapp-webhook`;
- sender `919891162212` was identified and mapped to the expected company context;
- intent classification completed;
- an automated reply was accepted by Click2API with HTTP 200;
- subsequent `sent`, `delivered`, and `read` status callbacks reached the same function;
- a second Click2API queue/status payload shape (`messaging_channel`, `message.queue_id`, `message.message_status`, `response.messages`) triggered a runtime error because the legacy fallback parser treated `payload.message` as text and later called `.toLowerCase()` on an object.

## Provider configuration evidence

The Click2API webhook editor exposes:

- title;
- callback URL;
- channel event selection.

No configurable webhook-signing secret, authentication header, verify-token field, or signature algorithm was exposed in the provider UI reviewed during this certification tranche.

The callback URL was therefore changed to use an unguessable provider-specific query token:

`?source=click2api&token=<redacted>`

The same value is stored as the Supabase Edge Function secret `WHATSAPP_WEBHOOK_VERIFY_TOKEN`.

## Repository remediation in this tranche

The canonical handler now:

1. authenticates Click2API callbacks against `WHATSAPP_WEBHOOK_VERIFY_TOKEN` before JSON parsing, logging, service-role client creation, database access, or downstream calls;
2. retains Meta HMAC-SHA256 validation for direct Meta callbacks through `X-Hub-Signature-256`;
3. validates GET challenge tokens before returning a challenge;
4. removes wildcard browser CORS from the webhook response surface;
5. parses the exact raw POST body only after provider authentication;
6. rejects malformed JSON before privileged processing;
7. detects nested Meta status callbacks and Click2API queue/status callbacks before message-intent parsing;
8. prevents non-string `payload.message` objects from becoming `messageBody`;
9. avoids logging raw inbound webhook payloads at the handler boundary.

## Remaining production evidence required

After merge and controlled deployment:

- valid Click2API token + inbound text -> HTTP 200 and normal Central ingestion;
- missing/invalid Click2API token -> rejected before DB/log/downstream processing;
- Click2API queue status payload -> HTTP 200, no `.toLowerCase()` runtime error;
- nested Meta status payload -> HTTP 200 status acknowledgement;
- duplicate inbound message ID -> existing deduplication behavior remains intact;
- direct Meta callback -> valid signature accepted, invalid/missing signature rejected;
- production logs show no raw payload or token value logging.

Production sign-off remains withheld until these post-deployment checks are captured.
