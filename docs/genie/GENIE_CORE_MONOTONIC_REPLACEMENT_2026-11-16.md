# Genie G3 — Core monotonic migration replacement

**Source-only preparation, 16 November 2026.**

The earlier Core PR #536 preview applied migration IDs `20261115160000`, `20261116120000`, `20261116140000`, and `20261116160000` on an isolated branch. Core `main` advanced to a migration version ceiling of `20261116143000`; older IDs added by #536 consequently violate canonical monotonicity and cannot be force-renamed without damaging migration history.

This new clean branch is based directly on Core main `289081bdb04b90f0f6b3ad28b8b8f597aa213759` and defines **two new additive production-intended migration IDs** above that ceiling. It does not include any historical edits, no-op compatibility bypasses, backfills, or the prior preview-only forward repair:

1. `20261117010000_genie_cart_operation_id_v2.sql`: original latest hardened transactional operation-ID receipt, replay authority, RLS/revoked direct table grants, audited buyer scope.
2. `20261117010100_genie_cart_atomic_quantity_update_v1.sql`: final atomic expected-quantity CAS with company → active parent draft → line lock order, original v1 commercial authority, receipt line-FK index.

Four PostgreSQL pgTAP suites are retained, including replay, cross-company/invalid operation tests, CAS authorization, checkout lock order, and receipt constraints. Rollback instructions require explicit protected-release authorization and draining Buyer traffic. Codacy's T-SQL false positives are excluded only for these two exact PostgreSQL rollback filenames.

**This is not a production migration nor a preview test.** Verify clean exact-head GitHub migration replay and the newly created preview on a distinct paid isolated branch before any protected merge. Do not reuse an old preview that has already applied the superseded migration versions. Close/supersede #536 only when the replacement PR is independently reviewed and the previous preview has been safely retired. Do not adjust old migration ledger rows, reset the existing preview, bypass the sequence check, deploy Core production, or enable Genie.
