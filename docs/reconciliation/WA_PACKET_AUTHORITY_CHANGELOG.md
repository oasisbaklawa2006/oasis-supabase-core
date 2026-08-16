# Packet Authority Changelog

- Added Core-owned `stitch_whatsapp_messages_atomic(uuid, uuid[], integer)`.
- Serialized packet mutation per contact with transaction-scoped advisory locking.
- Locked source messages before classification/linking.
- Made exact replay idempotent and mixed/conflicting replay fail closed.
- Enforced the configured packet window (300 seconds by default): a batch spanning beyond the window is rejected, and every fragment in an append must remain within the configured distance from the existing packet boundary.
- Rejected explicit null or out-of-range packet windows fail closed.
- Added provider/message database uniqueness through a separate non-transactional concurrent-index migration so inbound WhatsApp writes remain available during index construction.
- Added behavioural and static pgTAP contracts, including null-window and mixed-distance batch cases.
- Preserved existing historical packets and evidence without repair or rewriting.
