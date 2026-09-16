# Point66 current-main WhatsApp identity integration

Date: 2026-09-17

This branch supersedes the stale/conflicted Point66 sender-identity branch and reconciles its fail-closed sender≠customer behavior onto current Core main.

Repository-level invariants to certify on the exact head:

- staff relay or forwarded sender identity is not treated as commercial customer authority;
- governed customer resolution returns no company for ambiguous or unresolved identity;
- fuzzy company auto-linking, shadow-company creation and cross-company order retargeting remain absent;
- outgoing/status events are filtered before inbound durable ownership;
- inbound `whatsapp_messages` durable ownership is established before WAMID/debug dedupe can acknowledge success;
- duplicate provider-message persistence is idempotent; non-duplicate persistence failure returns retryable HTTP 503;
- WA-1 order-write quarantine remains fail-closed.

This document is repository evidence only. It does not claim production deployment or live-provider certification.
