# APP_AI_STUDIO_INTENT_APPENDIX.md

## Current AI Studio Handover Notes

AI Studio owns:

- Product master and aliases.
- Product media and generated assets.
- Resolver runtime and catalogue loader.
- WhatsApp Studio bridge.
- Operator Inbox support for inbound message interpretation.
- Catalogue export/PDF/compliance backlog.

Current proven path:

```txt
public.whatsapp_messages
-> whatsapp-studio-inbox-bridge
-> whatsapp_inbound_messages
-> resolver_result_json
-> Operator Inbox
-> operator decision
-> whatsapp_sales_order_drafts
```

Important production compatibility note:

`product_aliases` currently works with:

```txt
product_id
alias_text
canonical_name
created_at
```

Do not assume `alias`, `alias_type`, or `is_active` in edge loader unless migration is applied.

## AI Studio Next Backlog

1. Final E2E evidence after webhook recovery.
2. Operator Inbox failed/unresolved diagnostic refinements.
3. Catalogue collection production verification.
4. Retail / wholesale / export PDF generation.
5. FSSAI and legal metrology dataset completion.
6. Resolver runtime version and error observability.
7. Dynamic frontend data export.
