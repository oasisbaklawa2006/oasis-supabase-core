# whatsapp-content-interpret

Authenticated, read-only B2B multimodal interpretation and decision-support helper for the governed WhatsApp operator workflow.

## Scope

The function accepts either one `provider_message_id` for backward compatibility or an ordered `provider_message_ids` packet (maximum 16). It re-loads every authoritative inbound message under the caller's RLS scope and interprets the packet as one chronological body of business evidence.

Supported evidence:

- English, Hindi/Devanagari and Roman Hinglish text, including common mistyping, misspelling, phonetic spelling and abbreviations;
- photographs, screenshots and handwritten order images;
- WhatsApp voice/audio evidence via speech-to-text followed by packet reasoning;
- video evidence;
- PDF documents and structured/scanned purchase orders.

The output contains derived normalized text plus an advisory B2B conclusion: likely intent, explicit facts with message provenance, candidate order lines, corrections/supersessions, ambiguities, confidence and a recommended next human action.

## Humanised decision boundary

AI is expected to reach a reasoned conclusion, but it has no commercial execution authority. `human_review_required` remains part of the conclusion contract and is forced true when media is unavailable or other infrastructure evidence gaps exist.

The interpreter cannot:

- create or promote a live order;
- reserve stock;
- approve credit or payment;
- promise price, stock, production or delivery;
- authorize disclosure;
- send customer replies.

Those remain governed human/authority actions in WA-1..WA-7.

## Authority and safety

- The caller supplies only provider message identifiers; message contents and media URLs are re-loaded from authoritative inbound rows under caller RLS.
- Original WhatsApp messages/media are never rewritten.
- Missing/forbidden requested evidence fails closed rather than silently dropping a fragment.
- Media URLs must use HTTPS and match an approved host suffix.
- `click2api.in` and the physically verified Meta attachment CDN `lookaside.fbsbx.com` are allowed by default; any other provider/CDN requires explicit `WHATSAPP_MEDIA_ALLOWED_HOSTS` configuration.
- Click2API credentials are attached only to `click2api.in` or its subdomains. Other approved hosts never receive those credentials.
- Redirects are rejected.
- Per-file and total packet byte limits bound server-side media processing.
- Unsupported media types fail closed.
- Ambiguous or unreadable facts must remain unresolved; the model is instructed never to invent product identity, SKU, quantity, pricing, customer identity, payment state, stock or delivery commitments.
- Later explicit corrections may supersede earlier facts only when the evidence supports that chronology, and both provenance records remain represented.

## AI gateway

The function uses the Lovable AI Gateway with the server-side `Lovable-API-Key` header:

- packet/multimodal reasoning: `google/gemini-3.6-flash` through `/v1/chat/completions`;
- voice transcription: `openai/gpt-4o-mini-transcribe` through `/v1/audio/transcriptions`.

It also detects gateway body-level upstream errors rather than relying only on HTTP status.

## Runtime configuration

Required:

- `LOVABLE_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

Required only when Click2API-hosted media needs authenticated download:

- `CLICK2API_API_KEY`
- optional `CLICK2API_ACCESS_TOKEN`

Optional comma-separated media host suffixes for a verified provider/CDN outside the defaults:

- `WHATSAPP_MEDIA_ALLOWED_HOSTS`

Do not add a media host until its provenance is confirmed from the provider contract or staging evidence.

## Runtime activation boundary

`tcxvcatsqqertcnycuop` is the sole **production** Supabase project. Earlier WhatsApp work was exercised against that project during the false-staging incident; migration lineage was subsequently recovered through the governed Core migration process.

Repository merge of this function does **not** authorize production deployment, runtime activation, production migration application, direct SQL, or business-data mutation. Physical B2B multimodal certification is required before any production activation and remains a separate gate from repository merge-readiness.

Central consumes `normalized_text` as derived evidence for existing catalogue-backed product/quantity resolution and surfaces the advisory AI conclusion to the operator. Immutable original packet evidence remains authoritative.
