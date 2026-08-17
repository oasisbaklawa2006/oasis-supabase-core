-- Contract for migration 20260817120300_whatsapp_packet_processor_service_role_privileges.sql.
begin;
select plan(10);

select ok(
  has_table_privilege('service_role','public.whatsapp_commercial_evidence','SELECT'),
  'service_role can read immutable commercial evidence for packet reconciliation'
);
select ok(
  not has_table_privilege('service_role','public.whatsapp_commercial_evidence','UPDATE'),
  'service_role cannot update immutable commercial evidence'
);
select ok(
  not has_table_privilege('service_role','public.whatsapp_commercial_evidence','DELETE'),
  'service_role cannot delete immutable commercial evidence'
);
select ok(
  has_table_privilege('service_role','public.whatsapp_packet_ai_interpretations','SELECT'),
  'service_role can read packet AI results for idempotency'
);
select ok(
  has_table_privilege('service_role','public.whatsapp_packet_ai_interpretations','INSERT'),
  'service_role can append packet AI results'
);
select ok(
  not has_table_privilege('service_role','public.whatsapp_packet_ai_interpretations','UPDATE'),
  'service_role cannot update packet AI results'
);
select ok(
  not has_table_privilege('service_role','public.whatsapp_packet_ai_interpretations','DELETE'),
  'service_role cannot delete packet AI results'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','INSERT'),
  'authenticated users cannot append packet AI results'
);
select ok(
  not has_table_privilege('anon','public.whatsapp_packet_ai_interpretations','INSERT'),
  'anon cannot append packet AI results'
);
select ok(
  has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','SELECT'),
  'authenticated inbox readers retain RLS-governed read surface'
);

select * from finish();
rollback;
