-- CONNECT-2 adversarial contract coverage for
-- 20260922120000_connect2_consumer_channel_authority.sql

begin;

select plan(47);

-- ---------------------------------------------------------------------------
-- Schema / security contract
-- ---------------------------------------------------------------------------

select has_table('public', 'connect_consumers', 'connect_consumers exists');
select has_table('public', 'connect_tokens', 'connect_tokens exists');
select has_table('public', 'connect_profiles', 'connect_profiles exists');
select has_table('public', 'connect_bindings', 'connect_bindings exists');
select has_table('public', 'connect_delivery_log', 'connect_delivery_log exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.connect_tokens'::regclass),
  'connect_tokens has RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.connect_tokens', 'SELECT')
  and not has_table_privilege('authenticated', 'public.connect_tokens', 'SELECT'),
  '19/20: anon and authenticated cannot directly read token/hash records'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.connect_authorize_and_project_v1(text,text,jsonb)'::regprocedure),
  'connect_authorize_and_project_v1 is SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.connect_authorize_and_project_v1(text,text,jsonb)'::regprocedure),
  'connect_authorize_and_project_v1 uses fixed search_path'
);

select ok(
  has_function_privilege('anon', 'public.connect_authorize_and_project_v1(text,text,jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.connect_authorize_and_project_v1(text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('public', 'public.connect_authorize_and_project_v1(text,text,jsonb)', 'EXECUTE'),
  'projection RPC is callable by anon/authenticated only'
);

select ok(
  not has_function_privilege('anon', 'public.connect_admin_issue_token_v1(uuid,text[],text,timestamptz,integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.connect_admin_issue_token_v1(uuid,text[],text,timestamptz,integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.connect_admin_issue_token_v1(uuid,text[],text,timestamptz,integer)', 'EXECUTE'),
  '24: admin token issuance is service_role only'
);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into public.products (
  id, name, product_name, category, sku, hsn_code, is_active,
  visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b
) values
  (
    'c2000000-0000-0000-0000-000000000001',
    'Connect Published', 'Connect Published', 'test', 'CONN-PUB-1', '1905',
    true, true, true, 1, 1, 650, 650
  ),
  (
    'c2000000-0000-0000-0000-000000000002',
    'Connect Draft', 'Connect Draft', 'test', 'CONN-DRAFT-1', '1905',
    true, false, false, 1, 1, 650, 650
  );

set local role service_role;

select is(
  (select count(*)::integer from public.connect_profiles where profile_key = 'b2c_india_v1'),
  1,
  'reference profile b2c_india_v1 seeded'
);

select ok(
  (public.connect_admin_register_consumer_v1(
    'connect-test-b2c-a', 'b2c_website', 'production', 'Connect Test B2C A'
  ) ->> 'consumer_id') is not null,
  'consumer A registered'
);

select ok(
  (public.connect_admin_register_consumer_v1(
    'connect-test-b2c-b', 'b2c_website', 'production', 'Connect Test B2C B'
  ) ->> 'consumer_id') is not null,
  'consumer B registered'
);

select ok(
  (public.connect_admin_register_consumer_v1(
    'connect-test-trace-a', 'trace_label', 'production', 'Connect Test Trace'
  ) ->> 'consumer_id') is not null,
  'trace consumer registered'
);

select throws_like(
  $sql$select public.connect_admin_issue_token_v1(
    (select id from public.connect_consumers where consumer_key = 'connect-test-b2c-a'),
    array['catalogue:read']::text[],
    'staging',
    now() + interval '1 hour',
    120
  )$sql$,
  '%CONNECT_ENVIRONMENT_MISMATCH%',
  'admin token issuance rejects consumer/token environment mismatch'
);

select throws_like(
  $sql$select public.connect_admin_bind_profile_v1(
    (select id from public.connect_consumers where consumer_key = 'connect-test-b2c-a'),
    (select id from public.connect_profiles where profile_key = 'b2c_india_v1'),
    'staging'
  )$sql$,
  '%CONNECT_ENVIRONMENT_MISMATCH%',
  'admin profile binding rejects consumer/binding environment mismatch'
);

with c as (
  select id from public.connect_consumers where consumer_key = 'connect-test-b2c-a'
), p as (
  select id from public.connect_profiles where profile_key = 'b2c_india_v1'
)
select ok(
  (select public.connect_admin_bind_profile_v1(c.id, p.id, 'production') ->> 'binding_id'
   from c, p) is not null,
  'consumer A bound to b2c profile'
);

with c as (
  select id from public.connect_consumers where consumer_key = 'connect-test-b2c-a'
), p as (
  select id from public.connect_profiles where profile_key = 'b2c_india_v1'
), rebound as (
  select public.connect_admin_bind_profile_v1(c.id, p.id, 'production') from c, p
)
select is(
  (select count(*)::integer
     from public.connect_bindings b, c
    where b.consumer_id = c.id
      and b.environment = 'production'
      and b.status = 'active'),
  1,
  'rebinding preserves exactly one active profile per consumer/environment'
)
from rebound;

with c as (
  select id from public.connect_consumers where consumer_key = 'connect-test-b2c-b'
), p as (
  select id from public.connect_profiles where profile_key = 'b2c_india_v1'
)
select ok(
  (select public.connect_admin_bind_profile_v1(c.id, p.id, 'production') ->> 'binding_id'
   from c, p) is not null,
  'consumer B bound to b2c profile'
);

with c as (
  select id from public.connect_consumers where consumer_key = 'connect-test-trace-a'
), p as (
  select id from public.connect_profiles where profile_key = 'trace_label_v1'
)
select ok(
  (select public.connect_admin_bind_profile_v1(c.id, p.id, 'production') ->> 'binding_id'
   from c, p) is not null,
  'trace consumer bound to trace profile'
);

-- Issue tokens and capture consumer ids
create temp table connect_test_fixtures on commit drop as
with consumer as (
  select id, consumer_key from public.connect_consumers
  where consumer_key in ('connect-test-b2c-a', 'connect-test-b2c-b', 'connect-test-trace-a')
)
select
  c.id as consumer_id,
  c.consumer_key,
  public.connect_admin_issue_token_v1(
    c.id,
    case c.consumer_key
      when 'connect-test-b2c-a' then array['catalogue:read', 'delivery:record']::text[]
      when 'connect-test-b2c-b' then array['catalogue:read', 'delivery:record']::text[]
      else array['trace:label:read', 'delivery:record']::text[]
    end,
    'production',
    now() + interval '7 days',
    120
  ) as issued
from consumer c;

select ok(
  (select count(*) = 3 from connect_test_fixtures),
  'three test tokens issued'
);

select set_config(
  'connect.test.token_b2c_a',
  (select issued ->> 'token' from connect_test_fixtures where consumer_key = 'connect-test-b2c-a'),
  true
);
select set_config(
  'connect.test.token_b2c_b',
  (select issued ->> 'token' from connect_test_fixtures where consumer_key = 'connect-test-b2c-b'),
  true
);
select set_config(
  'connect.test.token_trace_a',
  (select issued ->> 'token' from connect_test_fixtures where consumer_key = 'connect-test-trace-a'),
  true
);
select set_config(
  'connect.test.consumer_b2c_a',
  (select consumer_id::text from connect_test_fixtures where consumer_key = 'connect-test-b2c-a'),
  true
);

reset role;

-- ---------------------------------------------------------------------------
-- 1. Valid B2C consumer -> approved published catalogue -> allowed
-- ---------------------------------------------------------------------------

select ok(
  (
    select (public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.products',
      '{}'::jsonb
    ) ->> 'ok')::boolean
  ),
  '1: valid B2C consumer receives approved catalogue projection'
);

select ok(
  (
    select exists (
      select 1
      from jsonb_array_elements(
        public.connect_authorize_and_project_v1(
          current_setting('connect.test.token_b2c_a'),
          'catalogue.products',
          jsonb_build_object('product_id', 'c2000000-0000-0000-0000-000000000001')
        ) -> 'data'
      ) row
      where row ->> 'sku' = 'CONN-PUB-1'
    )
  ),
  '1: published product appears in projection'
);

-- ---------------------------------------------------------------------------
-- 2. B2C consumer -> B2B pricing -> denied
-- ---------------------------------------------------------------------------

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.pricing.b2b',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '2: B2C consumer cannot request B2B pricing resource'
);

-- ---------------------------------------------------------------------------
-- 3-8 Token failure modes
-- ---------------------------------------------------------------------------

set local role service_role;

update public.connect_tokens
   set revoked_at = now()
 where token_hash = public.connect_internal_hash_token_v1(current_setting('connect.test.token_b2c_b'));

insert into public.connect_tokens (
  consumer_id, token_hash, token_prefix, scopes, environment, expires_at
)
select
  c.id,
  public.connect_internal_hash_token_v1('oc_production_expiredfixturetoken1234567890abcdef'),
  'oc_productio',
  array['catalogue:read']::text[],
  'production',
  now() - interval '1 hour'
from public.connect_consumers c
where c.consumer_key = 'connect-test-b2c-a';

insert into public.connect_tokens (
  consumer_id, token_hash, token_prefix, scopes, environment
)
select
  c.id,
  public.connect_internal_hash_token_v1('oc_staging_wrongenvfixturetoken1234567890ab'),
  'oc_staging_',
  array['catalogue:read']::text[],
  'staging'
from public.connect_consumers c
where c.consumer_key = 'connect-test-b2c-a';

insert into public.connect_tokens (
  consumer_id, token_hash, token_prefix, scopes, environment
)
select
  c.id,
  public.connect_internal_hash_token_v1('oc_production_emptyscopefixturetoken123456789'),
  'oc_productio',
  array[]::text[],
  'production'
from public.connect_consumers c
where c.consumer_key = 'connect-test-b2c-a';

reset role;

select throws_like(
  $revoked$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_b'),
      'catalogue.products',
      '{}'::jsonb
    )
  $revoked$,
  '%CONNECT_%',
  '3: revoked token denied'
);

set local role service_role;
update public.connect_tokens
   set revoked_at = null
 where token_hash = public.connect_internal_hash_token_v1(current_setting('connect.test.token_b2c_b'));
reset role;

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      'oc_production_expiredfixturetoken1234567890abcdef',
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '4: expired token denied'
);

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      'oc_production_totally_invalid_token_value_1234567890abcd',
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '5: invalid token denied'
);

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      'short',
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '6: malformed short token denied'
);

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      'oc_staging_wrongenvfixturetoken1234567890ab',
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '7: wrong environment token denied'
);

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      'oc_production_emptyscopefixturetoken123456789',
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '18: empty-scope consumer denied'
);

-- ---------------------------------------------------------------------------
-- 8. Wrong scope denied
-- ---------------------------------------------------------------------------

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_trace_a'),
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '8: trace token without catalogue:read scope denied for catalogue.products'
);

-- ---------------------------------------------------------------------------
-- 9. Trace-scoped token requesting pricing -> denied
-- ---------------------------------------------------------------------------

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_trace_a'),
      'catalogue.pricing.b2b',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '9: trace-scoped token cannot request pricing'
);

-- ---------------------------------------------------------------------------
-- 10. Website-scoped token requesting internal fields -> denied
-- ---------------------------------------------------------------------------

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.products',
      '{"fields":["cost"]}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '10/17: undeclared/internal field request denied'
);

-- ---------------------------------------------------------------------------
-- 12. Draft/unapproved product never emitted
-- ---------------------------------------------------------------------------

select ok(
  not exists (
    select 1
    from jsonb_array_elements(
      public.connect_authorize_and_project_v1(
        current_setting('connect.test.token_b2c_a'),
        'catalogue.products',
        jsonb_build_object('product_id', 'c2000000-0000-0000-0000-000000000002')
      ) -> 'data'
    ) row
  ),
  '12: draft/unapproved product is never emitted'
);

-- ---------------------------------------------------------------------------
-- 13-14. Disabled / suspended consumer denied
-- ---------------------------------------------------------------------------

set local role service_role;
update public.connect_consumers set status = 'disabled' where consumer_key = 'connect-test-b2c-b';
reset role;

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_b'),
      'catalogue.products',
      '{}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '13: disabled consumer denied'
);

set local role service_role;
update public.connect_consumers set status = 'suspended' where consumer_key = 'connect-test-b2c-b';
reset role;

select throws_like(
  $suspended$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_b'),
      'catalogue.products',
      '{}'::jsonb
    )
  $suspended$,
  '%CONNECT_%',
  '14: suspended consumer denied'
);

set local role service_role;
update public.connect_consumers set status = 'active' where consumer_key = 'connect-test-b2c-b';
reset role;

-- ---------------------------------------------------------------------------
-- 15 / 23. Idempotent delivery replay without duplicate side effect
-- ---------------------------------------------------------------------------

select ok(
  (
    select (public.connect_record_delivery_v1(
      current_setting('connect.test.token_b2c_a'),
      'connect-test-idem-001',
      'catalogue.products',
      'fp-connect-test-001',
      'success'
    ) ->> 'idempotency_replayed')::boolean = false
  ),
  '15: first delivery record succeeds'
);

select ok(
  (
    select (public.connect_record_delivery_v1(
      current_setting('connect.test.token_b2c_a'),
      'connect-test-idem-001',
      'catalogue.products',
      'fp-connect-test-001',
      'success'
    ) ->> 'idempotency_replayed')::boolean
  ),
  '15/23: replay returns deterministic idempotency_replayed=true'
);

select ok(
  (
    select (public.connect_record_delivery_v1(
      current_setting('connect.test.token_b2c_b'),
      'connect-test-idem-001',
      'catalogue.products',
      'fp-connect-test-001',
      'success'
    ) ->> 'idempotency_replayed')::boolean = false
  ),
  'consumer-scoped idempotency allows the same key for a different consumer without replay collision'
);

set local role service_role;

select ok(
  (
    select count(*) = 2
       and count(distinct consumer_id) = 2
      from public.connect_delivery_log
     where idempotency_key = 'connect-test-idem-001'
  )
  and (
    select count(*) = 2
      from public.connect_delivery_log d
      join connect_test_fixtures f on f.consumer_id = d.consumer_id
     where d.idempotency_key = 'connect-test-idem-001'
       and f.consumer_key in ('connect-test-b2c-a', 'connect-test-b2c-b')
  ),
  '15/23: idempotency is isolated to exactly one row for each expected consumer'
);

reset role;

-- ---------------------------------------------------------------------------
-- 11. Consumer isolation on delivery log ownership
-- ---------------------------------------------------------------------------

select ok(
  (
    select (public.connect_record_delivery_v1(
      current_setting('connect.test.token_b2c_a'),
      'connect-test-idem-002',
      'catalogue.products',
      'fp-connect-test-002',
      'success'
    ) ->> 'consumer_id')
  ) = current_setting('connect.test.consumer_b2c_a'),
  '11: delivery log consumer_id is derived from token consumer, not caller-supplied identity'
);

-- ---------------------------------------------------------------------------
-- 16. Forged profile identifier in params is ignored (binding governs)
-- ---------------------------------------------------------------------------

select ok(
  (
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.products',
      '{"profile_key":" forged_profile "}'::jsonb
    ) ->> 'profile_key'
  ) = 'b2c_india_v1',
  '16: forged profile identifier in params does not override binding'
);

-- ---------------------------------------------------------------------------
-- 21-22. SQL injection / malformed payload bounded failure
-- ---------------------------------------------------------------------------

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.products',
      '{"fields":["sku; drop table products"]}'::jsonb
    )
  $$,
  '%CONNECT_%',
  '21: SQL injection styled field request fails closed'
);

select throws_like(
  $$
    select public.connect_authorize_and_project_v1(
      current_setting('connect.test.token_b2c_a'),
      'catalogue.products',
      jsonb_build_object('limit', 999999)
    )
  $$,
  '%CONNECT_%',
  '22: excessive pagination limit rejected'
);

-- ---------------------------------------------------------------------------
-- 24. Privilege escalation through profile/binding mutation denied
-- ---------------------------------------------------------------------------

set local role authenticated;

select throws_like(
  $$select public.connect_admin_bind_profile_v1(gen_random_uuid(), gen_random_uuid(), 'production')$$,
  '%permission denied%',
  '24: authenticated caller cannot bind profiles through admin RPC'
);

select throws_like(
  $$insert into public.connect_bindings (consumer_id, profile_id, environment) values (gen_random_uuid(), gen_random_uuid(), 'production')$$,
  '%permission denied%',
  '24: authenticated caller cannot insert bindings directly'
);

reset role;

select * from finish();
rollback;
