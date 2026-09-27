# T5-WA-001 runtime provider closure — 2026-09-27

This record closes the remaining provider-dependent Task 5 WhatsApp runtime gate using read-only production evidence. No production mutation, replay, synthetic send, or manufactured provider event was performed for this certification.

## Scope

- Production project: `tcxvcatsqqertcnycuop`
- Consumer function: `whatsapp-operator-reply-consumer` v1, `verify_jwt=false`
- Scheduler: `whatsapp-operator-reply-consumer-minute`, active, `* * * * *`
- Covered Core revision retained from the deployed consumer certification: `d6c6a662703c04f90f7e79c790d3b994f9a61f1b`

## Provider acceptance evidence

A naturally occurring autonomous outbox item was observed read-only:

- reply id: `b803a364-8d36-4a5a-ba3a-918f3d3c2025`
- message origin: `AUTONOMOUS`
- created: `2026-09-26 06:01:09.774874+00`
- provider accepted: `2026-09-26 06:02:01.515866+00`
- Click2API acceptance identifier: `8817da5f-218d-4e00-b0f3-5cf33db06922`
- outbox status: `ACCEPTED`
- no last-error code

The recipient is deliberately not reproduced in this evidence file.

## Direct Click2API → Meta identifier mapping

A read-only lookup of `debug_webhooks.raw_payload.message.queue_id` using the
accepted outbox item's Click2API identifier returned **exactly one** applicable
mapping row and **exactly one** distinct Meta message identifier:

- mapping webhook row: `3b398952-6719-4521-9c74-d452e7784a80`
- Click2API `queue_id`: `8817da5f-218d-4e00-b0f3-5cf33db06922`
- Click2API message status in the mapping payload: `sent`
- Meta message identifier:
  `wamid.HBgMOTE5OTcxNzc3MDA2FQIAERgSNTQzQzcxQTFGRkQ3QTI2NERDAA==`
- mapping row count: **1**
- distinct Meta message identifier count: **1**

The mapping payload itself contains both identifiers in the same persisted
provider response object: `message.queue_id` carries the Click2API acceptance
identifier and `response.messages[0].id` carries the Meta message identifier.
This is the direct provider-to-Meta correlation required before the ledger may
state `ALLOW`; recipient/time correlation is retained only as secondary
consistency evidence.

## Delivery and read evidence

Within 30 seconds of the above provider acceptance, production `debug_webhooks` contains one matching service-message status chain for the same recipient:

1. `sent` — webhook row `d603f023-61a5-492f-8571-0a45bdd74361` at `2026-09-26 06:02:07.033533+00`
2. `delivered` — webhook row `57dbcea2-120d-46e4-8bc1-addc2d447ea3` at `2026-09-26 06:02:07.306008+00`
3. `read` — webhook row `ae4fea81-9d62-4d60-8fd7-a631964650b8` at `2026-09-26 06:02:11.578631+00`

All three callbacks carry the same Meta message identifier:

`wamid.HBgMOTE5OTcxNzc3MDA2FQIAERgSNTQzQzcxQTFGRkQ3QTI2NERDAA==`

This provides provider delivery/read evidence for the production path without creating a new message.

## Alert / reconciliation closure evidence

The previously observed autonomous acceptance-unknown item `1de36ceb-ebc0-4406-84ae-ba1ef47387e7` did not remain indefinitely ambiguous.

Production event history shows:

- `PROVIDER_ACCEPTANCE_UNKNOWN` with `NETWORK_TIMEOUT`
- later `QUARANTINED` at `2026-09-27 12:13:14.368637+00`
- reason: `STALE_AUTONOMOUS_ACCEPTANCE_UNKNOWN_NO_PROVIDER_ID`
- disposition: `DO_NOT_SEND`

This proves the abnormal-path reconciliation closes fail-safe without blind replay.

## Certification conclusion

The specific release-gate statement in `T5-WA-001` is now stale. Production evidence demonstrates:

- deployed consumer execution;
- real provider acceptance identifier;
- provider sent/delivered/read callback chain; and
- fail-safe reconciliation of the acceptance-unknown condition.

Therefore `T5-WA-001` may move from `BLOCKED_EXTERNAL / BLOCK` to `RUNTIME_VERIFIED / ALLOW`.

This does not claim that the newer #348 atomic outbox delivery/read persistence is already live. That forward change remains subject to the Protected Production Migration Release and governed named `whatsapp-webhook` deployment.
