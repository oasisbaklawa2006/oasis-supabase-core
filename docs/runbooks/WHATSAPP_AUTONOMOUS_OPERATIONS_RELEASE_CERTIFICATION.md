# WhatsApp Autonomous Operations — pre-production release certification

This ledger reports **actual evidence**, not launch prose. It is not a
production go-live.

Corpus rule: historical B2B WhatsApp groups are **employee-mediated**. Raw
private exports are never committed.

Status vocabulary:

- **CODE_COMPLETE** — merged Core/Central/Studio software exists with pgTAP and harness evidence
- **STAGING_CERTIFIED** — executed against staging credentials/load/provider with recorded evidence
- **PRODUCTION_CERTIFIED** — owner-approved production release evidence

| Requirement                           | Status                         | Evidence                                                                                                                                       |
| ------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Gate 1 human-review-not-default       | CODE_COMPLETE on Core `main`   | CORE-A `#111` `whatsapp_evaluate_and_materialize_order_autonomy`                                                                               |
| Gate 2 governed field materialisation | CODE_COMPLETE on Core `main`   | CORE-A `#111`                                                                                                                                  |
| Gate 3 auto-draft                     | CODE_COMPLETE on Core `main`   | CORE-B `#112`                                                                                                                                  |
| Gate 4 auto SO progression            | CODE_COMPLETE on Core `main`   | CORE-B `#112` `whatsapp_execute_autonomous_order_draft_v1`                                                                                     |
| Gate 5 clarification + resume         | CODE_COMPLETE on Core `main`   | CORE-C `#114` merged                                                                                                                           |
| Gate 6 communication policy           | CODE_COMPLETE on Core `main`   | CORE-C `#114` ack/clarify/receipt + non-order governance                                                                                       |
| Gate 7 non-order routing              | CODE_COMPLETE on Core `main`   | CORE-C `#114` team+SLA routing                                                                                                                 |
| Gate 8 Central exception-first        | CODE_COMPLETE                  | Central exception UI merged                                                                                                                      |
| Gate 9 AI Studio knowledge plane      | CODE_COMPLETE                  | AI Studio knowledge plane + Core knowledge bridge merged                                                                                        |
| Gate 10 95% certification             | HARNESS READY; corpus pending  | CERT-A harness scores **sanitized synthetic** cases against live Core; representative historical corpus requires protected owner run             |
| Gate 11 enterprise hardening          | CODE_COMPLETE on Core `main`   | Gate 11 `#116` merged (`whatsapp_autonomy_gate11_hardening.test.sql`)                                                                          |
| Gate 12 festival load                 | STAGING_CERTIFICATION pending  | no staging load/chaos evidence in repository CI                                                                                                  |
| Gate 13 zero-loss recon               | CODE_COMPLETE (partial staging)| WA-1 `unaccounted_potential_orders` on `main`; autonomy CONVERTED recert in Gate 11 `#116`                                                       |
| Gate 14 pre-production claim          | NOT launch-ready               | synthetic harness pass ≠ staging/provider certified                                                                                              |

## CERT-A harness (PR `#115`)

Architecture:

1. **GoldenCase** — sanitized input + ground truth + expected outcome
2. **ObservedResult** — independently read from live Core tables/RPC return payload
3. **Scorer** — compares observed vs golden; fails closed on any safety violation

Executable:

```sh
supabase db reset --local
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  deno run --allow-env --allow-net --allow-read scripts/whatsapp-autonomy-eval/run_sanitized.ts
deno test scripts/whatsapp-autonomy-eval/score.test.ts
```

Protected representative historical corpus (never committed):

```sh
WA_PROTECTED_CORPUS_PATH=/secure/path/outside/git/sanitized_historical_v1.json \
  deno run --allow-env --allow-net --allow-read scripts/whatsapp-autonomy-eval/run_protected.ts
```

Release bar encoded in the scorer:

- dangerous automated commercial false positives must be **zero**
- complaint / UNCLEAR / missing quantity / cancellation / payment advice / policy-blocked cases must not auto-action
- scorer must **not** treat golden labels as observed runtime results
- straight-through rate is reported on the synthetic corpus only; **do not claim >=95%** until a protected historical run exists

Current sanitized set: **12** synthetic cases covering clear employee-mediated order, family term, missing qty, complaint, UNCLEAR/failed interpretation, frozen credit, cancellation, payment advice, invented commercial terms, UOM ambiguity, shared-phone cross-customer protection, and duplicate replay safety.

Representative historical traffic certification remains a **TRUE OWNER BUSINESS DECISION** and protected off-git process.

**NO PRODUCTION DEPLOYMENT.**
