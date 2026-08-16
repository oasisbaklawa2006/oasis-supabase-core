# whatsapp-content-interpret

Authenticated, read-only interpretation helper for the governed WhatsApp operator workflow.

## Authority and safety

- The caller supplies only `provider_message_id`; the function re-loads the authoritative inbound row under the caller's RLS scope.
- Original WhatsApp message and media records are never rewritten.
- Image bytes are fetched server-side and are bounded to supported image formats and 8 MiB.
- Media URLs must use HTTPS and match an approved host suffix. `click2api.in` is allowed by default; additional provider/CDN hosts require explicit `WHATSAPP_MEDIA_ALLOWED_HOSTS` configuration.
- Click2API credentials are attached only when the approved media URL itself is on `click2api.in` or a subdomain. Redirects are rejected so credentials and server-side fetch authority cannot be redirected elsewhere.
- Hindi/Hinglish normalization and image reading must preserve explicit product, SKU, quantity, unit and correction facts only.
- Ambiguous or unreadable facts remain unresolved; the interpreter must never invent product identity, quantity, pricing, customer identity or delivery commitments.
- This function is interpretation-only. It cannot promote drafts, write orders, reserve stock, send replies or weaken WA-1..WA-7 authority.

## Runtime configuration

Required for model-backed Hindi/image interpretation:

- `LOVABLE_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

Required when Click2API-hosted media needs authenticated download:

- `CLICK2API_API_KEY`
- optional `CLICK2API_ACCESS_TOKEN`

Optional comma-separated media host suffixes for a verified provider/CDN that is not under `click2api.in`:

- `WHATSAPP_MEDIA_ALLOWED_HOSTS`

Do not add a media host until its provenance is confirmed from the provider contract or staging evidence.

The Central operator inbox consumes returned `normalized_text` as derived evidence for its existing read-only product and quantity resolvers. The immutable original packet remains the source evidence.
