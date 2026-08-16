# WA Packet Mutation Threat Model

Protected properties:

- one provider event cannot become two raw commercial fragments;
- two concurrent stitcher invocations for the same contact cannot inflate or split the packet solely because of a race;
- messages from different contacts cannot be stitched together;
- a closed packet cannot be mutated by the atomic RPC;
- a partial failure cannot commit packet counters without fragment links;
- exact invocation replay is idempotent.

Mechanisms: provider/message unique index, per-contact transaction advisory lock, row locks, contact/direction validation, open-packet predicate, one PostgreSQL transaction, service-role-only execution, and pgTAP regression coverage.
