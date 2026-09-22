begin;
-- Contract coverage for migration
-- 20260921120000_display_device_remote_config_authority.sql.

select plan(32);

select has_table('public','display_device_registry_v1','display device registry exists');
select ok((select relrowsecurity from pg_class where oid='public.display_device_registry_v1'::regclass),'display registry has RLS');
select is(has_table_privilege('authenticated','public.display_device_registry_v1','SELECT'),false,'browser cannot read display registry directly');

select has_function('public','admin_assign_display_device_v1',array['text','text','text','text','text'],'assign RPC exists');
select has_function('public','admin_list_display_devices_v1',array[]::text[],'list RPC exists');
select has_function('public','admin_revoke_display_device_v1',array['text'],'revoke RPC exists');
select has_function('public','display_enrollment_code_hash_v1',array['text'],'keyed enrollment-code representation exists');
select has_function('public','display_device_assignment_v1',array['text','text','text','text','text'],'atomic device assignment RPC exists');

select is(has_function_privilege('anon','public.admin_assign_display_device_v1(text,text,text,text,text)','EXECUTE'),false,'anon cannot assign');
select is(has_function_privilege('authenticated','public.admin_assign_display_device_v1(text,text,text,text,text)','EXECUTE'),true,'authenticated can invoke subject to admin check');
select is(has_function_privilege('anon','public.admin_list_display_devices_v1()','EXECUTE'),false,'anon cannot list');
select is(has_function_privilege('anon','public.admin_revoke_display_device_v1(text)','EXECUTE'),false,'anon cannot revoke');
select is(has_function_privilege('anon','public.display_enrollment_code_hash_v1(text)','EXECUTE'),false,'anon cannot invoke enrollment-code hasher');
select is(has_function_privilege('authenticated','public.display_enrollment_code_hash_v1(text)','EXECUTE'),false,'authenticated cannot invoke enrollment-code hasher');
select is(has_function_privilege('service_role','public.display_enrollment_code_hash_v1(text)','EXECUTE'),false,'service role cannot invoke enrollment-code hasher directly');
select is(has_function_privilege('anon','public.display_device_assignment_v1(text,text,text,text,text)','EXECUTE'),false,'anon cannot invoke device assignment RPC');
select is(has_function_privilege('authenticated','public.display_device_assignment_v1(text,text,text,text,text)','EXECUTE'),false,'authenticated cannot invoke device assignment RPC');
select is(has_function_privilege('service_role','public.display_device_assignment_v1(text,text,text,text,text)','EXECUTE'),true,'service role can invoke device assignment RPC');

select ok(
  position(
    'extensions.hmac(' in
    pg_get_functiondef('public.display_enrollment_code_hash_v1(text)'::regprocedure)
  ) > 0,
  'enrollment codes use keyed HMAC protection'
);
select ok(
  position(
    'display_enrollment_code_hash_v1' in
    pg_get_functiondef('public.admin_assign_display_device_v1(text,text,text,text,text)'::regprocedure)
  ) > 0,
  'admin assignment uses the protected enrollment-code representation'
);
select ok(
  position(
    'display_token_hash IS NULL' in
    pg_get_functiondef('public.display_device_assignment_v1(text,text,text,text,text)'::regprocedure)
  ) > 0,
  'enrollment claim only succeeds before a token is claimed'
);
select ok(
  position(
    'RETURNING * INTO v_row' in
    pg_get_functiondef('public.display_device_assignment_v1(text,text,text,text,text)'::regprocedure)
  ) > 0,
  'assignment data is sourced from the successful state update'
);

set local request.jwt.claim.role='authenticated';
set local request.jwt.claim.sub='';
select throws_like(
  $$select public.admin_list_display_devices_v1()$$,
  '%DISPLAY_ADMIN_REQUIRED%',
  'list fails closed without admin actor'
);
select throws_like(
  $$select public.admin_revoke_display_device_v1('tv-00000000-0000-0000-0000-000000000000')$$,
  '%DISPLAY_ADMIN_REQUIRED%',
  'revoke fails closed without admin actor'
);

select isnt(
  public.display_enrollment_code_hash_v1('ABC12345'),
  encode(extensions.digest(convert_to('ABC12345', 'UTF8'), 'sha256'), 'hex'),
  'enrollment-code representation is not a plain SHA-256 digest'
);

insert into public.display_device_registry_v1(
  device_id, enrollment_code_hash, surface_key, friendly_name, location
) values (
  'tv-00000000-0000-0000-0000-000000000001',
  public.display_enrollment_code_hash_v1('ABC12345'),
  'arabic-sweets',
  'Contract TV',
  'Test bay'
);

set local role service_role;

select ok(
  result->>'status' = 'ok'
  and result->>'authMode' = 'enrollment'
  and result#>>'{assignment,surfaceKey}' = 'arabic-sweets',
  'first enrollment atomically claims the token and returns its assignment'
)
from (
  select public.display_device_assignment_v1(
    'tv-00000000-0000-0000-0000-000000000001',
    'ABC12345',
    null,
    repeat('a', 64),
    '1.0.0'
  ) as result
) claimed;

select is(
  (select display_token_hash from public.display_device_registry_v1
    where device_id = 'tv-00000000-0000-0000-0000-000000000001'),
  repeat('a', 64),
  'successful enrollment persists the issued token hash'
);

select ok(
  result->>'status' = 'enrollment_code_invalid'
  and not (result ? 'assignment'),
  'a later enrollment claimant receives neither an assignment nor a token claim'
)
from (
  select public.display_device_assignment_v1(
    'tv-00000000-0000-0000-0000-000000000001',
    'ABC12345',
    null,
    repeat('b', 64),
    '1.0.1'
  ) as result
) duplicate_claim;

select is(
  (select display_token_hash from public.display_device_registry_v1
    where device_id = 'tv-00000000-0000-0000-0000-000000000001'),
  repeat('a', 64),
  'a losing enrollment claimant cannot overwrite the winning token hash'
);

select ok(
  result->>'status' = 'ok'
  and result->>'authMode' = 'token'
  and result#>>'{assignment,surfaceKey}' = 'arabic-sweets',
  'valid token authentication updates activity and returns the assignment'
)
from (
  select public.display_device_assignment_v1(
    'tv-00000000-0000-0000-0000-000000000001',
    null,
    repeat('a', 64),
    null,
    '1.0.2'
  ) as result
) token_poll;

select ok(
  (select apk_version = '1.0.2' and last_seen_at is not null
     from public.display_device_registry_v1
    where device_id = 'tv-00000000-0000-0000-0000-000000000001'),
  'successful token authentication persists activity before returning configuration'
);

select ok(
  result->>'status' = 'device_token_invalid'
  and not (result ? 'assignment'),
  'invalid token authentication returns no assignment'
)
from (
  select public.display_device_assignment_v1(
    'tv-00000000-0000-0000-0000-000000000001',
    null,
    repeat('c', 64),
    null,
    '1.0.3'
  ) as result
) invalid_token;

reset role;

select * from finish();
rollback;
