# WA Atomic Packet Acceptance Gates

The change is acceptable only when all of the following are true:

1. Clean zero-state migration replay passes.
2. pgTAP passes, including exact replay, cross-contact rejection, five-minute append/new-packet behaviour, and provider retry uniqueness.
3. Database lint and migration governance pass.
4. `anon` and `authenticated` cannot execute packet mutation.
5. Central is changed separately to invoke `stitch_whatsapp_messages_atomic`; no direct packet insert/update remains in the production stitcher path.
6. No production migration/history repair is performed.
7. Final physical certification accounts for every inbound provider event and every outbound operator action exactly once.
