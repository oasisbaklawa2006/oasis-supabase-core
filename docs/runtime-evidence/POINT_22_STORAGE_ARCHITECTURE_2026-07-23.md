# Point 22 — Shared Storage Architecture

Production project: `tcxvcatsqqertcnycuop`

## Implemented

- Added `storage_bucket_contracts` as the authority register for bucket classification, owning application, public-delivery intent, write authority, path convention and migration status.
- Preserved public delivery for `product-images` and `product-media`.
- Removed anonymous and broad authenticated writes from product media buckets; writes now require internal staff authority.
- Removed public receipt reads and restricted receipt access to owner folders or internal staff.
- Restricted customer trade-document uploads to the caller's own folder.
- Restricted WhatsApp attachments to internal staff.
- Made `final-invoices`, `proforma-invoices` and legacy `trade_documents` private.
- Registered underscore `trade_documents` as a legacy-review bucket; no object was moved or deleted.

## Runtime evidence

Bucket visibility after migration:

- public: `product-images`, `product-media`
- private: `final-invoices`, `proforma-invoices`, `receipts`, `trade-documents`, `trade_documents`, `whatsapp_attachments`

Object counts remained unchanged:

- product-images: 351
- product-media: 51
- receipts: 48
- trade-documents: 23
- trade_documents: 2

Unsafe policies removed:

- anonymous product-image insert/update/delete
- broad authenticated product-media writes
- public receipt reads
- unrestricted authenticated trade-document uploads

## Boundary

The two objects in legacy `trade_documents` were isolated by making the bucket private and registering it for migration review. This tranche did not rename or delete that bucket because live caller evidence is incomplete.

## Truth classification

- DOCUMENTED: yes
- CODED: yes
- MIGRATED: yes
- TESTED: yes
- DEPLOYED: yes
- RUNTIME VERIFIED: yes
