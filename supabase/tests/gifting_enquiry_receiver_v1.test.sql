-- Gifting enquiry receiver contract coverage for
-- 20261119020000_gifting_enquiry_receiver_v1.sql and
-- 20261119020050_gifting_enquiry_receiver_validation.sql (Central #677; Gifting PR #37).

begin;

select plan(59);

-- ---------------------------------------------------------------------------
-- Fixtures: two enquiry consumers, one retail read consumer, token variants
-- ---------------------------------------------------------------------------
create temp table _g (k text primary key, v text not null) on commit drop;

do $$
declare
  v_profile uuid := (select id from public.connect_profiles where profile_key = 'gifting_enquiries_v1');
  v_retail_profile uuid := (select id from public.connect_profiles where profile_key = 'website_retail_v1');
  v_a jsonb; v_b jsonb; v_r jsonb; v_t jsonb;
begin
  v_a := public.connect_admin_register_consumer_v1('gtest-enquiries-a', 'b2c_website', 'staging', 'Gifting A');
  v_b := public.connect_admin_register_consumer_v1('gtest-enquiries-b', 'b2c_website', 'staging', 'Gifting B');
  v_r := public.connect_admin_register_consumer_v1('gtest-retail', 'b2c_website', 'staging', 'Retail');
  perform public.connect_admin_bind_profile_v1((v_a ->> 'consumer_id')::uuid, v_profile, 'staging');
  perform public.connect_admin_bind_profile_v1((v_b ->> 'consumer_id')::uuid, v_profile, 'staging');
  perform public.connect_admin_bind_profile_v1((v_r ->> 'consumer_id')::uuid, v_retail_profile, 'staging');

  v_t := public.connect_admin_issue_token_v1((v_a ->> 'consumer_id')::uuid, array['enquiries:gifting:write'], 'staging');
  insert into _g values ('consumer_a', v_a ->> 'consumer_id'), ('tok_a', v_t ->> 'token'), ('tokid_a', v_t ->> 'token_id');
  v_t := public.connect_admin_issue_token_v1((v_b ->> 'consumer_id')::uuid, array['enquiries:gifting:write'], 'staging');
  insert into _g values ('tok_b', v_t ->> 'token');
  -- right profile, wrong scope
  v_t := public.connect_admin_issue_token_v1((v_a ->> 'consumer_id')::uuid, array['catalogue:read'], 'staging');
  insert into _g values ('tok_wrong_scope', v_t ->> 'token');
  -- right scope, but the consumer is bound to a read-only retail profile
  v_t := public.connect_admin_issue_token_v1((v_r ->> 'consumer_id')::uuid, array['enquiries:gifting:write', 'catalogue:read'], 'staging');
  insert into _g values ('tok_retail', v_t ->> 'token');
  -- expired and revoked
  v_t := public.connect_admin_issue_token_v1((v_a ->> 'consumer_id')::uuid, array['enquiries:gifting:write'], 'staging', now() - interval '1 minute');
  insert into _g values ('tok_expired', v_t ->> 'token');
  v_t := public.connect_admin_issue_token_v1((v_a ->> 'consumer_id')::uuid, array['enquiries:gifting:write'], 'staging');
  perform public.connect_admin_revoke_token_v1((v_t ->> 'token_id')::uuid);
  insert into _g values ('tok_revoked', v_t ->> 'token');
  -- suspended consumer
  v_t := public.connect_admin_issue_token_v1((v_b ->> 'consumer_id')::uuid, array['enquiries:gifting:write'], 'staging');
  insert into _g values ('tok_b2', v_t ->> 'token');

  insert into _g values
    ('lead1', gen_random_uuid()::text), ('lead2', gen_random_uuid()::text),
    ('lead3', gen_random_uuid()::text), ('lead4', gen_random_uuid()::text);
end $$;

create or replace function pg_temp.g(p_key text) returns text language sql stable as $$
  select v from _g where k = p_key
$$;

create or replace function pg_temp.payload(p_overrides jsonb default '{}'::jsonb) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'kind', 'corporate',
    'email', 'buyer@example.test',
    'phone', '+919999900000',
    'name', 'Test Buyer',
    'company', 'Example Co',
    'message', 'We need 200 gift boxes.',
    'source', 'business-page',
    'consent', jsonb_build_object('marketing', false, 'timestamp', null),
    'attribution', jsonb_build_object('utm_source', 'newsletter')
  ) || p_overrides
$$;

create or replace function pg_temp.receive(p_token text, p_lead text, p_payload jsonb) returns jsonb
language sql as $$
  select public.gifting_enquiry_receive_v1(p_token, p_lead::uuid, p_payload)
$$;

-- ---------------------------------------------------------------------------
-- Schema / privilege contract
-- ---------------------------------------------------------------------------
select ok(
  (select relrowsecurity from pg_class where oid = 'public.gifting_enquiries'::regclass),
  'gifting_enquiries has RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.gifting_enquiries', 'SELECT')
  and not has_table_privilege('authenticated', 'public.gifting_enquiries', 'SELECT')
  and not has_table_privilege('anon', 'public.gifting_enquiries', 'INSERT')
  and not has_table_privilege('authenticated', 'public.gifting_enquiries', 'INSERT'),
  'anon and authenticated have no direct access to enquiry personal data'
);

select ok(
  has_function_privilege('service_role', 'public.gifting_enquiry_receive_v1(text,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.gifting_enquiry_receive_v1(text,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.gifting_enquiry_receive_v1(text,uuid,jsonb)', 'EXECUTE'),
  'receiver is executable by service_role only'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.gifting_enquiry_receive_v1(text,uuid,jsonb)'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public']
         from pg_proc where oid = 'public.gifting_enquiry_receive_v1(text,uuid,jsonb)'::regprocedure),
  'receiver is SECURITY DEFINER with a fixed search_path'
);

select ok(
  exists (
    select 1 from public.connect_profiles
     where profile_key = 'gifting_enquiries_v1'
       and allowed_resources = array['enquiries.gifting']::text[]
       and cardinality(allowed_fields) = 0
  ),
  'write-only profile exposes no catalogue resource and no readable fields'
);

-- ---------------------------------------------------------------------------
-- First delivery
-- ---------------------------------------------------------------------------
create temp table _r1 on commit drop as
  select pg_temp.receive(pg_temp.g('tok_a'), pg_temp.g('lead1'), pg_temp.payload()) as r;

select is((select r ->> 'status' from _r1), 'accepted', 'first delivery is accepted');
select is((select r ->> 'queue' from _r1), 'gifting_enquiries', 'receipt names the gifting_enquiries queue');
select is((select r ->> 'sourceLeadId' from _r1), pg_temp.g('lead1'), 'receipt echoes the source lead UUID');
select ok((select (r ->> 'enquiryId') ~ '^[0-9a-f-]{36}$' from _r1), 'receipt carries a stable enquiry id');
select is((select r ->> 'replayed' from _r1), 'false', 'first delivery is not a replay');
select is(
  (select count(*)::int from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  1,
  'exactly one enquiry row exists after the first delivery'
);
select is(
  (select marketing_consent::text from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  'false',
  'marketing consent is stored as supplied (off)'
);

-- ---------------------------------------------------------------------------
-- Duplicate delivery / replay
-- ---------------------------------------------------------------------------
create temp table _r2 on commit drop as
  select pg_temp.receive(
    pg_temp.g('tok_a'),
    pg_temp.g('lead1'),
    -- same content, different key order
    jsonb_build_object(
      'attribution', jsonb_build_object('utm_source', 'newsletter'),
      'consent', jsonb_build_object('timestamp', null, 'marketing', false),
      'source', 'business-page',
      'message', 'We need 200 gift boxes.',
      'company', 'Example Co',
      'name', 'Test Buyer',
      'phone', '+919999900000',
      'email', 'buyer@example.test',
      'kind', 'corporate'
    )
  ) as r;

select is((select r ->> 'enquiryId' from _r2), (select r ->> 'enquiryId' from _r1), 'replay returns the same enquiry id');
select is((select r ->> 'replayed' from _r2), 'true', 'replay is flagged as a replay');
select is(
  (select count(*)::int from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  1,
  'replay does not create a second row'
);
select is(
  (select receipt_count from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  2,
  'replay increments the receipt counter only'
);

-- ---------------------------------------------------------------------------
-- Conflicting payload for the same source lead
-- ---------------------------------------------------------------------------
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload(%L::jsonb))$q$,
    pg_temp.g('tok_a'), pg_temp.g('lead1'), '{"message":"A different message."}'),
  'P0001',
  'GIFTING_ENQUIRY_PAYLOAD_CONFLICT',
  'a different payload for an existing source lead is rejected'
);

select is(
  (select message from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  'We need 200 gift boxes.',
  'the conflicting attempt did not change the stored enquiry'
);

select is(
  (pg_temp.receive(pg_temp.g('tok_a'), pg_temp.g('lead1'), pg_temp.payload()) ->> 'enquiryId'),
  (select r ->> 'enquiryId' from _r1),
  'an exact replay still succeeds after a rejected conflicting attempt'
);

-- ---------------------------------------------------------------------------
-- Tenant isolation: the same source UUID from another consumer is a separate row
-- ---------------------------------------------------------------------------
select isnt(
  (pg_temp.receive(pg_temp.g('tok_b'), pg_temp.g('lead1'), pg_temp.payload()) ->> 'enquiryId'),
  (select r ->> 'enquiryId' from _r1),
  'the same source UUID from a different consumer is stored separately'
);
select is(
  (select count(*)::int from public.gifting_enquiries where source_lead_id = pg_temp.g('lead1')::uuid),
  2,
  'idempotency is scoped per consumer'
);

-- ---------------------------------------------------------------------------
-- Authentication / authorization
-- ---------------------------------------------------------------------------
select throws_ok(
  format($q$select pg_temp.receive('short', %L, pg_temp.payload())$q$, pg_temp.g('lead2')),
  'P0001', 'CONNECT_TOKEN_INVALID', 'a malformed token is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, repeat('x', 40), pg_temp.g('lead2')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'an unknown token is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, pg_temp.g('tok_wrong_scope'), pg_temp.g('lead2')),
  'P0001', 'CONNECT_SCOPE_DENIED', 'a token without the write scope is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, pg_temp.g('tok_retail'), pg_temp.g('lead2')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'a retail read-profile consumer cannot write enquiries even with the scope'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, pg_temp.g('tok_expired'), pg_temp.g('lead2')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'an expired token is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, pg_temp.g('tok_revoked'), pg_temp.g('lead2')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'a revoked token is rejected'
);

update public.connect_consumers set status = 'suspended' where consumer_key = 'gtest-enquiries-b';
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload())$q$, pg_temp.g('tok_b2'), pg_temp.g('lead2')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'a suspended consumer is rejected'
);

select is(
  (select count(*)::int from public.gifting_enquiries where source_lead_id = pg_temp.g('lead2')::uuid),
  0,
  'no row was written by any rejected authentication attempt'
);

select throws_ok(
  format($q$select public.connect_authorize_and_project_v1(%L, 'catalogue.products', '{}'::jsonb)$q$, pg_temp.g('tok_a')),
  'P0001', 'CONNECT_AUTHORIZATION_DENIED', 'the enquiry token cannot read the catalogue projection'
);

select ok(
  (select last_used_at is not null from public.connect_tokens where id = pg_temp.g('tokid_a')::uuid),
  'a successful delivery records token use'
);

-- ---------------------------------------------------------------------------
-- Payload validation
-- ---------------------------------------------------------------------------
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"kind":"newsletter"}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'marketing-only kinds (newsletter) are not accepted'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"kind":"rewards"}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'marketing-only kinds (rewards) are not accepted'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"unexpected":"x"}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'unknown payload fields are rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"email":"not-an-email"}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'a malformed email is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload(jsonb_build_object('message', repeat('m', 2001))))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'an over-long message is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload() - 'consent')$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'missing consent is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"consent":{"marketing":"yes","timestamp":null}}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'non-boolean marketing consent is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"consent":"yes"}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'a scalar consent value is rejected'
);
select throws_ok(
  format($q$select pg_temp.receive(%L, %L, pg_temp.payload('{"attribution":{"utm_source":5}}'::jsonb))$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'non-string attribution values are rejected'
);
select throws_ok(
  format($q$select public.gifting_enquiry_receive_v1(%L, null, pg_temp.payload())$q$, pg_temp.g('tok_a')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'a missing source lead id is rejected'
);
select throws_ok(
  format($q$select public.gifting_enquiry_receive_v1(%L, %L::uuid, '[]'::jsonb)$q$, pg_temp.g('tok_a'), pg_temp.g('lead3')),
  '22023', 'GIFTING_ENQUIRY_INVALID', 'a non-object payload is rejected'
);
select is(
  (select count(*)::int from public.gifting_enquiries where source_lead_id = pg_temp.g('lead3')::uuid),
  0,
  'no row was written by any invalid payload'
);

-- A valid enquiry with marketing consent granted keeps the consent timestamp.
select is(
  (pg_temp.receive(
     pg_temp.g('tok_a'), pg_temp.g('lead4'),
     pg_temp.payload('{"kind":"wedding","consent":{"marketing":true,"timestamp":"2026-11-18T10:00:00Z"}}'::jsonb)
   ) ->> 'status'),
  'accepted',
  'a wedding enquiry with granted consent is accepted'
);

-- NULL scope elements must not turn a missing permission into authorization.
do $$
declare a uuid := (select id from public.connect_consumers where consumer_key = 'gtest-enquiries-a');
        r uuid := (select id from public.connect_consumers where consumer_key = 'gtest-retail');
        x jsonb;
begin
  x := public.connect_admin_issue_token_v1(a, array['catalogue:read',null]::text[], 'staging');
  insert into _g values ('tok_null_wrong',x->>'token');
  x := public.connect_admin_issue_token_v1(a, array['enquiries:gifting:write',null]::text[], 'staging');
  insert into _g values ('tok_null_right',x->>'token');
  x := public.connect_admin_issue_token_v1(r, array['enquiries:gifting:write',null]::text[], 'staging');
  insert into _g values ('tok_read_null_wrong',x->>'token');
  x := public.connect_admin_issue_token_v1(r, array['catalogue:read',null]::text[], 'staging');
  insert into _g values ('tok_delivery_null_wrong',x->>'token');
  x := public.connect_admin_issue_token_v1(r, array['catalogue:read','delivery:record',null]::text[], 'staging');
  insert into _g values ('tok_delivery_null_right',x->>'token');
end $$;
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload())$q$,pg_temp.g('tok_null_wrong')),
 'P0001','CONNECT_SCOPE_DENIED','NULL element cannot grant the gifting write scope');
select lives_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload())$q$,pg_temp.g('tok_null_right')),
 'an explicit gifting write scope still works with a NULL sibling');
select throws_ok(format($q$select * from public.connect_internal_resolve_authorization_v1(%L,'catalogue.products')$q$,pg_temp.g('tok_read_null_wrong')),
 'P0001','CONNECT_SCOPE_DENIED','NULL element cannot grant catalogue read scope');
select throws_ok(format($q$select * from public.connect_internal_resolve_authorization_v1(%L,'catalogue.products',true)$q$,pg_temp.g('tok_delivery_null_wrong')),
 'P0001','CONNECT_SCOPE_DENIED','NULL element cannot grant delivery scope');
select lives_ok(format($q$select * from public.connect_internal_resolve_authorization_v1(%L,'catalogue.products',true)$q$,pg_temp.g('tok_delivery_null_right')),
 'explicit read and delivery scopes still work with a NULL sibling');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"now"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: now');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"today"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: today');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"tomorrow"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: tomorrow');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"yesterday"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: yesterday');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"infinity"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: infinity');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"-infinity"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: -infinity');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"2026-11-18"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: 2026-11-18');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"2026-11-18T10:00:00"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: 2026-11-18T10:00:00');
select throws_ok(format($q$select pg_temp.receive(%L, gen_random_uuid()::text, pg_temp.payload(%L::jsonb))$q$,
 pg_temp.g('tok_a'), '{"consent":{"marketing":false,"timestamp":"2026-99-18T10:00:00Z"}}'),
 '22023','GIFTING_ENQUIRY_INVALID','non-absolute or invalid consent date is rejected: 2026-99-18T10:00:00Z');
select is((pg_temp.receive(pg_temp.g('tok_a'),pg_temp.g('lead4'),
 pg_temp.payload('{"kind":"wedding","consent":{"marketing":true,"timestamp":"2026-11-18T10:00:00Z"}}'::jsonb))->>'replayed'),
 'true','a fixed ISO consent timestamp preserves exact replay');

select * from finish();

rollback;
