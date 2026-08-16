# WhatsApp Multimodal + Hindi Interpretation Certification

This closure supplements WA-4/WA-7 physical certification. It does not alter order, reply, disclosure, promotion, RLS, AAL2, audit or idempotency authority.

## Required staging physical cases

1. Send a Hindi text order using Devanagari digits and product wording (for example, the Hindi equivalent of 5 kg Pyramid). Verify the original text remains immutable and the operator resolution receives only a derived normalized interpretation.
2. Send a clear order photograph containing product/SKU and quantity text. Verify the image is preserved, the server-side interpreter contributes derived text to product/quantity resolution, and no unsupported fact is invented.
3. Send an unreadable/ambiguous image. Verify the system fails closed and requires human review rather than inventing order facts.
4. Send unrelated image content. Verify it does not create a product/quantity order line.
5. Confirm a normal English text-only packet still resolves through the existing deterministic path without requiring interpretation.
6. Confirm provider-message, packet, customer and evidence boundaries remain unchanged.

## Release gate

GO requires: Core CI green, Central PR CI green, no genuine unresolved review findings, and staging physical proof for both a Hindi text order and an image order. Production remains untouched until the normal release approval path.
