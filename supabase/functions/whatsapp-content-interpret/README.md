# whatsapp-content-interpret

Authenticated, read-only interpretation helper for the governed WhatsApp operator workflow.

## Authority and safety

- The caller supplies only `provider_message_id`; the function re-loads the authoritative inbound row under the caller's RLS scope.
- Original WhatsApp message and media records are never rewritten.
- Image bytes are fetched server-side using provider credentials and are bounded to supported image formats and 8 MiB.
- Hindi/Hinglish normalization and image reading must preserve explicit product, SKU, quantity, unit and correction facts only.
- Ambiguous or unreadable facts remain unresolved; the interpreter must never invent product identity, quantity, pricing, customer identity or delivery commitments.
- This function is interpretation-only. It cannot promote drafts, write orders, reserve stock, send replies or weaken WA-1..WA-7 authority.

The Central operator inbox consumes returned `normalized_text` as derived evidence for its existing read-only product and quantity resolvers. The immutable original packet remains the source evidence.
