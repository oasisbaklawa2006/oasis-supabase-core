begin;
-- Behavioral coverage for 20260819103000_fwd_wa_normalization_runtime_correctness.sql.
select plan(6);

-- =================================================================================
-- 1. Phone-normalization regex: the actual bug pattern, tested directly.
--    '\D' (single backslash, the fix) matches non-digit characters as
--    intended; '\\D' (the historical bug, still preserved byte-for-byte in
--    the recovered migration this PR does not touch) is the literal
--    two-character sequence backslash-D and matches nothing in a realistic
--    phone number, so it is a no-op instead of a normalizer.
-- =================================================================================

select is(regexp_replace('+91 98765-43210', '\D', '', 'g'), '919876543210', 'corrected regex strips spaces and hyphens from an Indian mobile number');
select is(regexp_replace('(022) 4567-8900', '\D', '', 'g'), '02245678900', 'corrected regex strips brackets, spaces and hyphens from a landline-style number');
select is(regexp_replace('919876543210', '\D', '', 'g'), '919876543210', 'corrected regex is a no-op on an already-normalized number');
select is(regexp_replace('', '\D', '', 'g'), '', 'corrected regex handles empty input without error');
select isnt(regexp_replace('+91 98765-43210', '\\D', '', 'g'), '919876543210', 'sanity: the historical buggy pattern (double backslash) does NOT normalize the same input -- confirms the fix is not a no-op');

-- =================================================================================
-- 2. capture_whatsapp_payment_proof_evidence: the payment-evidence hash
--    resolves deterministically through the function's own search_path
--    (pg_catalog, public, auth) now that digest() is qualified as
--    extensions.digest(), exercised through the actual governed call path
--    (AI-detector branch, gated on auth.jwt()->>'role' = 'service_role').
-- =================================================================================

insert into public.whatsapp_contacts (id, phone_number) values
  ('90000000-0000-0000-0000-000000000001', '+919800000001');
insert into public.whatsapp_message_packets (id, contact_id, stitched_content, first_message_at, last_message_at) values
  ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '{}'::jsonb, now(), now());
insert into public.whatsapp_communication_cases (id, packet_id, rule_version) values
  ('92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 'pgtap-fixture-v1');
insert into public.whatsapp_messages (id, contact_id, packet_id, direction, provider, provider_message_id) values
  ('93000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 'inbound', 'meta', 'wamid.pgtap-fixture-1');

select set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
set local role service_role;

select lives_ok(
  $$ select public.capture_whatsapp_payment_proof_evidence(
       '92000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-000000000001',
       'AI', 1500.00, 'UTR123456789', 'corr-payment-proof-digest'
     ) $$,
  'capture_whatsapp_payment_proof_evidence resolves extensions.digest() deterministically through its own search_path and completes without a function-resolution error'
);

reset role;

select finish();
rollback;
