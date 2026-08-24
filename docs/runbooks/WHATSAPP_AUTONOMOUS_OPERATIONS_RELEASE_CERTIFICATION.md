# WhatsApp Autonomous Operations — pre-production release certification

This ledger reports **actual evidence**, not launch prose. It is not a production go-live.

Corpus rule: historical B2B WhatsApp groups are **employee-mediated**. Raw private exports are never committed.

| Requirement | Status | Evidence |
|---|---|---|
| Gate 1 human-review-not-default | COMPLETE on Core `main` | CORE-A `#111` `whatsapp_evaluate_and_materialize_order_autonomy` |
| Gate 2 governed field materialisation | COMPLETE on Core `main` | CORE-A `#111` |
| Gate 3 auto-draft | COMPLETE on Core `main` | CORE-B `#112` |
| Gate 4 auto SO progression | COMPLETE on Core `main` | CORE-B `#112` `whatsapp_execute_autonomous_order_draft_v1` |
| Gate 5 clarification + resume | STAGING-CERTIFICATION-ONLY until merge | Core PR `#114` CORE-C (CI green; human approval required) |
| Gate 6 communication policy | PARTIAL on `#114` | ack/clarify/receipt only; remaining status sends PHYSICAL/PROVIDER-ONLY + Core follow-on |
| Gate 7 non-order routing | PARTIAL on `#114` | team+SLA; full taxonomy residual |
| Gate 8 Central exception-first | STAGING-CERTIFICATION-ONLY | Central PR `#398` |
| Gate 9 AI Studio knowledge plane | STAGING-CERTIFICATION-ONLY | AI Studio PR `#126` (publish preview; Core activate not executed from Studio) |
| Gate 10 95% certification | NOT BLOCKED by code; corpus incomplete | this harness scores **sanitized synthetic** cases only; representative historical corpus is a TRUE OWNER BUSINESS DECISION + protected process |
| Gate 11 enterprise hardening | PARTIAL | CORE-A/B path tests on `main`; dedicated commercial-invention suite is independent of CORE-C merge |
| Gate 12 festival load | PHYSICAL/PROVIDER-ONLY / STAGING | no staging credentials in this agent |
| Gate 13 zero-loss recon | PARTIAL on `main` | WA-1 `unaccounted_potential_orders`; autonomy-path recert incomplete |
| Gate 14 pre-production claim | NOT launch-ready | unit/pgTAP ≠ staging proven |

## CERT-A harness (this PR)

Executable:

```
deno test scripts/whatsapp-autonomy-eval/score.test.ts
```

Release bar encoded in the scorer:

- dangerous auto-action false positives must be **zero** on the labeled set
- complaint / UNCLEAR / missing quantity must not be `auto_actioned`
- straight-through rate is reported, not hidden by dropping hard cases

Current sanitized set: 9 synthetic cases covering clear order, family term, missing qty, complaint, UNCLEAR, frozen credit, cancellation, payment advice, and invented-discount-with-master-price. This still does **not** satisfy >=95% on representative traffic. Expanding the protected historical corpus is a TRUE OWNER BUSINESS DECISION.
