# Packet Authority Changelog

- Added Core-owned `stitch_whatsapp_messages_atomic(uuid, uuid[], integer)`.
- Serialized packet mutation per contact with transaction-scoped advisory locking.
- Locked source messages before classification/linking.
- Made exact replay idempotent and mixed/conflicting replay fail closed.
- Enforced five-minute append boundary inside the transaction.
- Added provider/message database uniqueness.
- Added behavioural and static pgTAP contracts.
- Preserved existing historical packets and evidence without repair or rewriting.
