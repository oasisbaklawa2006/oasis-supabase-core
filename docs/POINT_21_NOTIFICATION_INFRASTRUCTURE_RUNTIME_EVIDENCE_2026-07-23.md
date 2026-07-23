# Point 21 — Notification Infrastructure Runtime Evidence

## Production project

`tcxvcatsqqertcnycuop`

## Existing state found

- 60 historical notification outbox rows
- 31 already marked sent
- 29 still pending since April 2026
- the pending rows covered account activation, B2B application receipt and advance-request events

## Production actions

- extended the existing `notification_outbox` rather than creating a duplicate queue
- added source application, channel, event linkage and idempotency identity
- added attempt limits, retry scheduling, lease ownership and provider acknowledgement fields
- added idempotent enqueue
- added service-role-only batch claim using `FOR UPDATE SKIP LOCKED`
- added retry and terminal failure transitions
- added successful delivery acknowledgement
- quarantined the 29 months-old pending messages instead of sending them automatically

## Runtime verification

Rollback-contained tests proved:

- same key and same payload returns the original notification ID
- same key and changed payload is rejected
- a due notification can be claimed once under a worker lease
- first failure enters retry
- retry can be reclaimed
- successful completion records provider identity and sent status
- no test notification remained after rollback

Final production checks:

- quarantined legacy rows: 29
- stale pending rows: 0
- persisted test rows: 0
- currently claimable rows: 0
- anonymous enqueue execution: denied
- authenticated batch claim: denied
- service-role batch claim: allowed

## Important boundary

Point 21 establishes queue governance and delivery-worker contracts. It does not itself deploy an email, WhatsApp, SMS or push worker and did not send any production notification during verification.

## Truth classification

- DOCUMENTED: yes
- CODED: yes
- MIGRATED: yes
- TESTED: yes
- DEPLOYED: yes
- RUNTIME VERIFIED: yes
