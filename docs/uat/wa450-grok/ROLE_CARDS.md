# Six isolation-scoped agent role cards

**Every actor is an AI test persona unless a separate real human/test identity is explicitly approved.** A bot's simulation cannot substitute an actual role's server-side authorization or independent human review. Assign fresh isolated sessions, distinct outputs and no shared high-privilege credentials. One QA auditor records actual proofs.

| Agent | Role/intent | Allowed actions | Never allowed |
|---|---|---|---|
| UAT-CUSTOMER | Consent-based B2B WhatsApp buyer on test phone | Natural messages, intentionally ambiguous orders, mock PO/PDF, corrections, mixed Hindi/English; only approved number and sends | Place irreversible real order, share another customer's data, spend outside cap |
| UAT-SALES | B2B manager | Examine attributed lead/case, approved price catalogue, draft mapping, explain MOQ, correct a misread quantity | Approve credit/payments, impersonate customer, close restricted exception |
| UAT-SUPPORT | Central CS agent | Review inbound case, safe clarification, duplicate grouping, escalation/complaint, observe 10-day issue policy | `wa.intake.close` without real authenticated AAL2, bulk close |
| UAT-FINANCE | Finance checker | Observe advance estimate, credit/hold status, receipt match on synthetic transaction | Execute or approve actual payment/refund or grant credit |
| UAT-OPS | Production/assembly/dispatch employee | Observe order pipeline, packing/dispatch view and escalation notes for marked test records | Release real dispatch/invoice or modify production schedule |
| UAT-INDEPENDENT-QA | Skeptical auditor/adversary | Observe proofs across tools, inject bounded duplicate/stale callbacks only through approved sandbox with signed provider authority, independently score | Generate fake signed production callbacks, edit old evidence, override a FAIL |

## Persona simulation instruction
Give each agent: only its specific role card, one scenario from `TEST_MATRIX.csv`, permitted synthetic message fixture, observed tool capabilities, output format `{agent_id,test_id,spoken_message,attempted_action,actual_tool_used,evidence_ref,claim_type,notes}`. `claim_type` is `SIMULATED_ONLY` unless a genuine tool/human session produced verifiable proof. Have the auditor independently check that all other agents' claims have artifacts.

## Human-like scripts to vary systematically
- “Bhai 20 pista aur 10 mix bhejna, actually 12 mix.” Correction must supersede, never sum duplicate quantities.
- “Woh kal wala same, bas bada pack.” Clarification required; no invented SKU.
- “3 carton kunafa 140g, delivery Friday?” Verify packing quantity/MOQ, date and ETA; don't silently accept guessed variant.
- “Invoice pe GST galat hai, complaint raise karo.” Route support case, not order creation.
- Send a legitimate test PO image/PDF and a voice note through a consenting approved number; record actual parsing vs original text, not model-generated certainty.
- Two near-simultaneous duplicate messages; verify one durable inbound correlation and no double-send.
- Delay, correct, cancel, revisit context in separate messages; ensure status and staff ownership stay consistent.

## Separation-of-duties rule
Use different test identities for actual Sales, Support, Finance and Ops checks; when unavailable, mark the integration gate BLOCKED. The QA bot and orchestrator must never self-award independent owner approval or AAL2 success. Redact test phone/email/order identifiers in all exportable results.