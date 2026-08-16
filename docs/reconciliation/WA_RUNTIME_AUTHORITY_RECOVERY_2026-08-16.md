# WhatsApp Runtime Authority Recovery — 2026-08-16

## Physical-test evidence

Read-only inspection of staging project `tcxvcatsqqertcnycuop` established:

- the six WA358 inbound test messages all existed in `whatsapp_messages` with distinct provider message IDs;
- the two photographs were preserved as commercial evidence but were in `UNREADABLE` processing state;
- the commercial evidence layer consolidated the test into one governed packet while legacy `whatsapp_message_packets` showed one-message fragmentation;
- no governed operator-reply outbox row existed for the reply typed in Central;
- deployed `banyan-central-parser` was stale executable legacy code and the active `banyan-flush-buffer` pg_cron job invoked it every 30 seconds;
- that deployed legacy function contained the exact unsolicited onboarding response observed on the physical handset and a direct Click2API sender;
- the runtime Banyan function was replaced with a 410 retired stub to contain the rogue outbound path; historical data was not rewritten.

## Core correction

`20260816120000_wa_atomic_packet_authority.sql` moves packet mutation authority into one PostgreSQL transaction. It serializes per contact with a transaction advisory lock, locks source rows, fails closed on mixed/cross-contact batches, appends only to an open packet inside the configured window, and links every fragment before commit. Exact replay returns the already-linked packet without incrementing counts.

A partial unique index on `(provider, btrim(provider_message_id))` prevents a provider retry from becoming a second raw event.

## Remaining certification boundary

This change does not rewrite historical fragmented packets. After merge/deployment, Central's stitcher must call the Core RPC instead of performing packet writes itself. The governed operator-reply pre-outbox failure and media `UNREADABLE` state remain separate closure items. A new physical test is required only after those runtime paths are corrected.
