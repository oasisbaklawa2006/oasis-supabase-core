# Core #484 / Studio #240 — chronological reconciliation candidate

Prepared: 21 November 2026. Base protected Core main `a227a9650d2fcf4a419930dbe05ee875485e02de`; original PR #580 `c186582d9cefe0a08ef22331eb6859b26f22d038`. No main/production modification, original-branch rewrite, Supabase Preview replacement, cost-incurring Preview creation or deployment is authorized by this preparation.

## Reason for candidate

Original unmerged Core #580 introduced immutable, already applied isolated-Preview versions `20261120170000` and `20261120180000` below the current main migration ceiling `20261120235700`. Main chronology CI and its dependent merge-governance check must stay fail-closed. Existing original Preview `miuojthdgftmoqqovfgp`, its ledger, historical files and evidence are preserved exactly.

This clean **candidate only** starts at current Core main and proposes one fresh forward migration `supabase/migrations/20261121133000_catalogue_media_publication_hold_reconciled_v1.sql` (above the current release ceiling), combining the original atomic approval trigger with the final validated media URL predicate, including hex/octal/short numeric host rejection. It does not add the original three Preview-applied timestamps. A protected release would select only ONE approach; original Core #580 and this candidate cannot both be merged.

## Security boundaries

The canonical approval dispatcher and wrapper remain unchanged. The trigger rejects approve transitions of media whose submitted or effective stored URL is private, temporary, staging, signed/authenticated, percent encoded, traversal-normalized, malformed, or noncanonical browser-numeric, causing rollback of earlier master writes in the same transaction. Ordinary DNS, canonical dotted IPv4, and durable public URL approvals remain eligible. Rejection and governed deletion remain intact. Neither a new unauthenticated grant nor Storage upload/promotion/publishing is included.

## Test and release gates

The copied `catalogue_media_publication_hold_v1.test.sql` has 20 synthetic held URL fixtures and **60 planned pgTAP assertions** covering wrapper/dispatcher, application roles, reviewer restrictions, rollback, public controls, and ACL. The old Preview's latest predicate passed 20/20 read-only cases; **these results are NOT full new-candidate replay or authenticated acceptance**. Do not state 60 tests passed before executing them.

Before creating a separately chargeable isolated Preview, obtain explicit owner authorization for the proposed reconciliation and its cost. Then execute a clean full migration replay, full pgTAP suite, database lint, current-main monotonicity and governance checks, authenticated HTTP/RPC owner/nonowner and positive/negative acceptance, audit rollback, and independent security/human approval. Do not waive checks, rewrite the old Preview's migration history, touch production, or automatically merge this branch.

The full Core #484 media promotion/provenance/expiry lifecycle remains separately incomplete.
