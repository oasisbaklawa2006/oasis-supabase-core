# WA Packet Review Checklist

- [ ] Migration timestamp is append-only.
- [ ] Existing provider IDs are duplicate-free before unique-index deployment.
- [ ] RPC is service-role only.
- [ ] Same-contact concurrent calls serialize.
- [ ] Cross-contact input fails closed.
- [ ] Exact replay does not increment fragment count.
- [ ] Outside-window input creates a new packet.
- [ ] Zero-state replay, pgTAP, lint, migration governance and ownership checks pass.
- [ ] No production mutation occurs as part of PR review.
