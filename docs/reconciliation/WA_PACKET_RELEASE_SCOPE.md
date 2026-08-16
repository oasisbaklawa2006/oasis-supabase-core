# WA Packet Release Scope

In scope: Core packet mutation atomicity/idempotency and provider-event uniqueness.

Out of scope for this Core PR: rewriting historical packets, Central UI redesign, operator-reply UX correction, media reprocessing, Click2API configuration, and production deployment.

Those remain separate gates so this database-authority change can be reviewed and replayed independently.
