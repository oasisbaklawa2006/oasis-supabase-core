# App-Verse Point 20 — Shared Immutable Event Ledger

## Production project

`tcxvcatsqqertcnycuop`

## Canonical authority

Point 20 extends the existing `public.operational_events` table. No competing event table was introduced.

## Implemented contract

- append-only update and delete guards retained
- canonical source application
- event schema version
- command name and command ID linkage
- correlation and causation linkage
- occurred-at versus recorded-at timestamps
- deterministic payload fingerprint
- source-scoped idempotency uniqueness
- same-key/same-payload replay returns the original event ID
- same-key/different-payload replay is rejected
- caller identity is bound to the authenticated user unless service-role execution is used
- anonymous execution is revoked

## Migration safety

The first production migration attempt was rejected by the existing append-only update trigger during legacy-row backfill. The transaction failed without partial application.

The migration was corrected to disable only the two named append-only triggers during the bounded one-time backfill inside the migration transaction, then immediately re-enable them before completion.

## Runtime verification

Rollback-contained production tests verified:

1. Same idempotency key and same payload returned the same event ID.
2. Same idempotency key and changed payload raised `idempotency key conflict`.
3. Direct UPDATE raised the existing append-only exception.
4. Direct DELETE raised the existing append-only exception.
5. All 20 pre-existing events were backfilled with source, version, occurrence time and payload fingerprint.
6. No persisted test event remained after rollback.

## Truth classification

- DOCUMENTED: yes
- CODED: yes
- MIGRATED: yes
- TESTED: yes
- DEPLOYED: yes
- RUNTIME VERIFIED: yes
