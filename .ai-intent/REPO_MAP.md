# Repository Ownership Map

## Purpose

This file defines ownership boundaries across the four-repo ecosystem.

| Repo | Purpose | Owns | Must Not Own |
|---|---|---|---|
| Architecture / Intent Repo | Master `.ai-intent`, architecture, handover, phase gates, screen registry | Intent docs, global backlog, system boundaries, runbooks, validation ledgers | Runtime business logic, secrets |
| Oasis Central | ERP/admin/order/finance/warehouse/dispatch | Golden Pipeline, Sales Orders, PI, billing, finance, warehouse, dispatch, Gatekeeper, approvals, CMD dashboard, tickets | Catalogue generation authority, AI media generation, final product truth mutation |
| Oasis AI Studio | Product intelligence/catalogue/media/resolver/WhatsApp bridge | Product master, media, aliases, resolver runtime, catalogue exports, WhatsApp Studio bridge, inbound operator inbox support | Final invoice, stock movement, dispatch clearance, legacy webhook redeploy |
| Oasis Labelling | Barcode/sticker/physical tracking/printer bridge | Label templates, barcode/QR generation, print queue, tracking nodes, reprint audit, printer integration | Product truth, order truth, finance, dispatch approval |

## Hard Boundary: WhatsApp

- `whatsapp-webhook` belongs to the legacy ERP/Central side.
- AI Studio owns only `whatsapp-studio-inbox-bridge`.
- Meta callback must remain on legacy webhook unless a separately approved migration exists.
