-- Recovered historical migration: reproduces the exact SQL applied to production
-- (tcxvcatsqqertcnycuop) under this version, fetched read-only via
-- the production migration ledger's statements column during the 2026-08-18
-- production migration lineage recovery. See
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv
-- for provenance.

grant select on table public.whatsapp_commercial_evidence to service_role;
grant select, insert on table public.whatsapp_packet_ai_interpretations to service_role;
revoke update, delete on table public.whatsapp_commercial_evidence from service_role;
revoke update, delete on table public.whatsapp_packet_ai_interpretations from service_role;
comment on table public.whatsapp_packet_ai_interpretations is 'Append-only advisory AI interpretations of immutable WhatsApp packets. service_role may append/read derived results; UPDATE/DELETE remain forbidden.';
