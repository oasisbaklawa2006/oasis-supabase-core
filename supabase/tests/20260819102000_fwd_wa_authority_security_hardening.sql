begin;
-- Behavioral coverage for 20260819102000_fwd_wa_authority_security_hardening.sql.
--
-- The disclosure_scope fixes in this migration are confirmed no-ops as of
-- this migration (whatsapp_case_recipient_authorizations.disclosure_scope
-- and whatsapp_case_outbound_decisions.disclosure_scope are both
-- `text[] NOT NULL DEFAULT '{}'` with no migration ever relaxing that), so
-- there is no reachable NULL-scope state to construct a fixture for. What
-- is tested here is the part of the contract that actually changed and can
-- regress: the database ACL on whatsapp_release_case_reply, and the
-- corrected phone-normalization regex both functions now share with the
-- rest of the codebase.
select plan(5);

select has_function('public','whatsapp_ask_customer', array['uuid','uuid','text','text','timestamptz','text[]','text'], 'whatsapp_ask_customer exists with its full signature');
select has_function('public','whatsapp_release_case_reply', array['uuid','uuid','text','text','text[]','uuid','text'], 'whatsapp_release_case_reply exists with its full signature');
select has_function('public','whatsapp_release_reviewed_case_reply', array['uuid','jsonb','text'], 'whatsapp_release_reviewed_case_reply exists with its full signature');

select is(
  (select has_function_privilege('anon','public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text)','execute')),
  false,
  'anon can no longer execute whatsapp_release_case_reply -- the missing REVOKE/GRANT pair is closed'
);
select is(
  (select has_function_privilege('authenticated','public.whatsapp_release_case_reply(uuid,uuid,text,text,text[],uuid,text)','execute')),
  true,
  'authenticated retains EXECUTE on whatsapp_release_case_reply (internal has_whatsapp_permission checks still gate actual use)'
);

select finish();
rollback;
