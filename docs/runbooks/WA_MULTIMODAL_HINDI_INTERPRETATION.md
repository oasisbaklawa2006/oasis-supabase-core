# WhatsApp B2B Multimodal AI Interpretation Certification

This closure supplements WA-4/WA-7 physical certification. It does not alter order, reply, disclosure, promotion, RLS, AAL2, audit or idempotency authority.

## Product contract

Current scope is B2B. WhatsApp evidence can arrive as:

- clean, mistyped or misspelled English;
- Hindi/Devanagari;
- Roman Hinglish, phonetic spellings and abbreviations;
- photographs and screenshots;
- handwritten order images;
- voice notes/audio in Hindi, English or Hinglish;
- video;
- PDF documents, including structured or scanned purchase orders;
- a chronological combination of the above across multiple WhatsApp fragments.

The AI layer must interpret the complete evidence packet and reach an advisory business conclusion. The conclusion may identify intent, explicit facts, candidate order lines, corrections/supersessions, ambiguities and a recommended next action. The final commercial decision remains human/authority governed.

The AI conclusion cannot itself create/promote a live order, reserve stock, approve credit/payment, promise price/availability/delivery, authorize disclosure or send a customer reply.

## Required staging physical cases

1. **Clean English** — send a simple B2B order and verify the complete packet is interpreted and catalogue-backed product/quantity resolution still agrees.
2. **Mistyped/misspelled English** — use realistic spelling errors/abbreviations (for example `snd 5 kg kaju pyramd same as lst tym`). Verify AI normalizes obvious language errors without inventing missing facts.
3. **Hindi/Devanagari** — send a Hindi text order with Hindi digits/product wording. Verify original source text remains immutable and a derived interpretation reaches the operator.
4. **Roman Hinglish** — send an order such as `mujhe 5 kilo kaju pyramd bhej do`. Verify the AI understands it even though it contains no Devanagari characters.
5. **Readable photograph/screenshot** — include explicit product/SKU and quantity. Verify visible facts contribute to the conclusion and catalogue resolution.
6. **Handwritten photograph** — send a legible handwritten order. Verify handwriting is interpreted as evidence with provenance and uncertainty where applicable.
7. **Unreadable/irrelevant image** — verify fail-closed/human review; no invented product or quantity.
8. **Voice note/audio** — send Hindi/English/Hinglish speech containing explicit B2B order facts. Verify speech-to-text is treated as evidence and the resulting conclusion cites the source message.
9. **Video** — send a short video containing relevant spoken/visible B2B order evidence. Verify AI can use the evidence while preserving ambiguity where unclear.
10. **Structured PDF PO** — send a PDF purchase order containing PO number, product rows, quantities/UOM and any delivery data. Verify only present facts are extracted.
11. **Scanned PDF PO** — verify visually scanned document evidence is handled or fails closed if illegible.
12. **Cross-fragment correction** — send an earlier quantity followed later by an explicit correction (for example `5 kg` then `not 5, make it 8 kg`). Verify the final conclusion records the later correction and preserves the superseded evidence.
13. **Mixed packet** — combine text + media across several fragments. Verify one packet-level AI conclusion rather than independent contradictory message conclusions.
14. **Provider media unavailable/expired** — verify the packet remains preserved and the AI result explicitly requires human review rather than silently ignoring the evidence.
15. **No legacy acknowledgement** — send a normal non-order text and verify the capture-only webhook does not emit the retired `Oasis Operations has received your message` acknowledgement.
16. **Governed manual reply** — verify an authorised operator reply is accepted once, does not encourage duplicate resend, and ACCEPTED/DELIVERED/READ callbacks reconcile through the governed outbox contract.

## Evidence checks for every case

- original message/media row remains immutable and authoritative;
- provider message ID, packet, customer and evidence boundaries remain intact;
- explicit corrections retain provenance;
- no default quantity is invented;
- AI confidence is not treated as execution authority;
- any ambiguity or missing media is visible to the human decision-maker;
- no direct live-order mutation occurs from interpreter or webhook;
- no legacy Banyan/automatic customer acknowledgement is executed.

## Automated release gate

Before physical pilot certification:

- Core Edge Function Governance PASS;
- Core Repo Ownership Boundaries PASS;
- Core Migration CI and Schema Drift PASS, including clean replay/pgTAP/DB lint;
- Central Repo Ownership Boundaries PASS;
- Central Release Quality Gate PASS, including typecheck, changed-file lint, unit/contracts, production build and Playwright smoke;
- no genuine unresolved review finding on the current PR heads;
- staging `whatsapp-content-interpret` is ACTIVE with `verify_jwt=true`;
- staging `whatsapp-webhook` remains custom-auth/capture-only with no customer-send authority.

## Pilot GO gate

The software may be classified **SOFTWARE-READY / PHYSICAL-DEVICE-ONLY** once all automated gates and staging deployments above pass. It may be classified **PHYSICALLY CERTIFIED for B2B multimodal interpretation** only after the required real WhatsApp cases are observed on the controlled staging/live-number environment.

Production remains untouched until the normal separately authorised release path.
