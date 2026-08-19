begin;
-- Contract coverage for migration
-- 20260819104000_whatsapp_packet_ai_interpretations_acl_hardening.sql
-- (Central issue #368 migration-train normalization, PROCEED phase 2A
-- section A).
select plan(9);

select ok(
  has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','SELECT'),
  'authenticated retains read-only access to governed packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','INSERT'),
  'authenticated cannot insert packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','UPDATE'),
  'authenticated cannot update packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','DELETE'),
  'authenticated cannot delete packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','TRUNCATE'),
  'authenticated cannot bypass RLS and append-only triggers with truncate'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','REFERENCES'),
  'authenticated has no REFERENCES privilege on packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','TRIGGER'),
  'authenticated has no TRIGGER privilege on packet AI interpretations'
);
select ok(
  not (
    has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','SELECT')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','INSERT')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','UPDATE')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','DELETE')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','TRUNCATE')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','REFERENCES')
    or has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','TRIGGER')
  ),
  'anon has zero privileges on packet AI interpretations'
);
select ok(
  not (
    has_table_privilege('public','public.whatsapp_packet_ai_interpretations','SELECT')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','INSERT')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','UPDATE')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','DELETE')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','TRUNCATE')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','REFERENCES')
    or has_table_privilege('public','public.whatsapp_packet_ai_interpretations','TRIGGER')
  ),
  'PUBLIC has zero privileges on packet AI interpretations'
);

select * from finish();
rollback;
