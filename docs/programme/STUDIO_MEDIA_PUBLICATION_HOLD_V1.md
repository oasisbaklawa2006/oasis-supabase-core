# Studio media publication containment — Core #484 / Studio #240

Base: Core main f1bc165b1fad3237ea35549aface24fa4fff9daa. No production mutation.

The deployed approval dispatcher writes `payload.file_url` into approved `product_media` without private Storage promotion. Studio #306 holds these approvals in the UI; a direct RPC still reaches the dispatcher. This append-only migration adds a draft-table trigger that rejects an approved create/update with private staging provenance or a private/temporary reference. It also checks the effective target URL, so metadata-only updates cannot approve an existing private object reference. The exception rolls back the whole approval SQL statement, including its earlier master-row insertion/update. Both the wrapper and direct dispatcher are covered.

The hold deliberately rejects percent-encoded references rather than implementing a second URL decoder/Storage authority. This can hold a previously accepted encoded durable URL; operators retain the draft for rejection or governed resolution. Existing approved rows are not scanned, changed or removed. Durable HTTP(S) URL-only approval, canonical reviewer checks, rejection and deletion requests stay governed by their existing functions. No Storage API operations, credentials, grants to application roles, Edge deployment or automatic publication are introduced.

## Validation and release

- 23 pgTAP assertions: private provenance aliases, staging bucket aliases, private URLs, signed/authenticated Storage routes, encoded bypass, malformed reference, staging public URL; public wrapper and dispatcher failures; pending draft and master-row rollback; durable approval; denied reviewer; effective URL on update; delete/reject continuity; helper/trigger ACL.
- Existing catalogue approval tests must continue to pass with clean database replay, migration lint, governance and required independent security review.
- No local PostgreSQL/Docker runner exists in this workspace. Source/governance checks are separate from remote pgTAP execution; never describe unexecuted contracts as passed.
- Keep DRAFT until exact-head CI and independent review complete, plus role/HTTP acceptance on the approved isolated Studio environment. Deploy only through the protected Core migration release after owner approval. Verify migration version, trigger and function definitions separately after release.

## Rollback and limits

No destructive data rewrite occurs. Retain this hold on rollback to older Studio builds. A future forward migration may replace the trigger only after a reviewed, server-authorized promotion contract and compatibility tests prove that draft approval cannot publish a private/signed reference. Do not disable the trigger or restore private approval as a quick rollback. Production monitoring should confirm held drafts remain pending and no partial approved master row persists after errors.

This containment does not implement signed preview issuance, upload/provenance/idempotency, Storage copy/promote, historical public URL retirement, or consumer certification. Core #484 remains open for that lifecycle. It does not change Product Master author, pricing, commercial or cross-app authority. The existing isolated preview migration failure remains a runtime acceptance blocker.
