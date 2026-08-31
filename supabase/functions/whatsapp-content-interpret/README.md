# whatsapp-content-interpret

Authenticated, read-only B2B multimodal interpretation and decision-support
helper for the governed WhatsApp operator workflow.

## Scope

The function accepts either one `provider_message_id` for backward compatibility
or an ordered `provider_message_ids` packet (maximum 16). It re-loads every
authoritative inbound message under the caller's RLS scope and interprets the
packet as one chronological body of business evidence.

Supported evidence:

- English, Hindi/Devanagari and Roman Hinglish text, including common mistyping,
  misspelling, phonetic spelling and abbreviations;
- photographs, screenshots and handwritten order images;
- WhatsApp voice/audio evidence interpreted directly as governed inline Gemini
  multimodal media together with the surrounding chronological packet;
- video evidence;
- PDF documents and structured/scanned purchase orders.

The output contains derived normalized text plus an advisory B2B conclusion:
likely intent, explicit facts with message provenance, candidate order lines,
corrections/supersessions, ambiguities, confidence and a recommended next human
action.

## Humanised decision boundary

AI is expected to reach a reasoned conclusion, but it has no commercial
execution authority. `human_review_required` remains part of the conclusion
contract and is forced true when media is unavailable or other infrastructure
evidence gaps exist.

The interpreter cannot:

- create or promote a live order;
- reserve stock;
- approve credit or payment;
- promise price, stock, production or delivery;
- authorize disclosure;
- send a WhatsApp reply.

## Request contract

Send one of:

```json
{ "provider_message_id": "wamid..." }
```

or:

```json
{ "provider_message_ids": ["wamid.1", "wamid.2", "wamid.3"] }
```

The caller must provide a valid authenticated `Authorization` bearer token. The
function re-reads the evidence from `whatsapp_messages`; arbitrary caller-provided
text or media URLs are not accepted as evidence.

## Media controls

Media is downloaded only from governed HTTPS provider/CDN hosts, redirects are
rejected, per-file and packet byte limits are enforced, and unsupported MIME
types fail closed. Provider credentials are read only in the Edge Runtime and
are never returned to callers.

## Provider contract

The current repository authority sends the bounded chronological multimodal
packet directly to Google Gemini through the shared governed Gemini adapter.
`GEMINI_API_KEY` is a server-side Edge Runtime secret and must never be exposed
to a browser or committed to source control.
