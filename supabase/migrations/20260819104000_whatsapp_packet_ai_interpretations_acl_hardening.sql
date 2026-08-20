begin;

-- Bounded ACL correction (Central issue #368 migration-train normalization,
-- PROCEED phase 2A section A). A pgTAP regression carried on open PR #82
-- ("authenticated cannot bypass RLS and append-only triggers with truncate")
-- failed against this table's real, canonical state on main -- exposing a
-- proven same-class ACL gap, not a hypothetical one.
--
-- Root cause: 20260817114750_whatsapp_packet_ai_interpretations.sql revoked
-- only INSERT, UPDATE, DELETE from authenticated (plus a separate REVOKE ALL
-- for anon). This schema's baseline default-privilege grant
-- (ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL
-- ON TABLES TO "authenticated", set in
-- 20260723161256_legacy_role_authority_baseline.sql) means every newly
-- created table starts with TRUNCATE, REFERENCES and TRIGGER already granted
-- to authenticated unless explicitly revoked per table. Revoking only
-- INSERT/UPDATE/DELETE never touched those three, so authenticated has
-- retained TRUNCATE (and REFERENCES/TRIGGER) on this table since its
-- creation.
--
-- Sibling append-only evidence tables from the same authority family
-- (whatsapp_commercial_evidence, whatsapp_commercial_packets,
-- whatsapp_packet_audit_log, whatsapp_media_processing_events,
-- whatsapp_packet_routing_events -- all hardened together in
-- 20260813180000_wa4_multimessage_multimodal.sql) used the correct
-- REVOKE ALL ... FROM public, anon, authenticated pattern and were verified
-- clean by this same bounded audit -- this is a single-table gap, not a
-- systemic one, so this migration touches only the one proven-defective
-- table.
--
-- This is a forward-only ACL correction. It does not restore, retimestamp,
-- or modify any historical migration file, and it changes nothing about
-- anon or PUBLIC, which already carry zero privileges on this table.

revoke all on table public.whatsapp_packet_ai_interpretations
  from public, anon, authenticated;

grant select on table public.whatsapp_packet_ai_interpretations
  to authenticated;

commit;
