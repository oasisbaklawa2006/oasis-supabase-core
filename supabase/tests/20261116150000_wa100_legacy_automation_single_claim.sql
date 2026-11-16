-- Contract for 20261116150000_wa100_legacy_automation_single_claim.sql
-- WA-100 #540: prove durable order+event claim is service-only and unique.
begin;
select plan(11);
select has_function('public','claim_legacy_whatsapp_automation_v1',
  array['uuid','text','text','text']);
select ok(exists(
  select 1 from pg_indexes where schemaname='public'
  and tablename='whatsapp_automations'
  and indexname='wa100_legacy_automation_order_trigger_once'
  and indexdef like 'CREATE UNIQUE INDEX%'
),'there is a unique order+trigger index');
select ok(has_function_privilege('service_role',
  'public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)','EXECUTE'),
  'service role may claim');
select ok(not has_function_privilege('authenticated',
  'public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)','EXECUTE'),
  'normal authenticated role may not claim');
select ok(not has_function_privilege('anon',
  'public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)','EXECUTE'),
  'anonymous role may not claim');

select ok(position('on conflict (order_id, trigger_type) do nothing' in lower(
  pg_get_functiondef('public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)'::regprocedure))) > 0,
  'repeat event is not inserted a second time');
select ok(position('status, retry_count' in lower(
  pg_get_functiondef('public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)'::regprocedure))) > 0,
  'new attempt records a pending event with zero retries');

select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($
  select public.claim_legacy_whatsapp_automation_v1(
    '55550000-0000-0000-0000-000000000001', 'so_created', '919800000000', 'so_confirmation')
$, '42501');

select set_config('request.jwt.claims','{"role":"service_role"}',true);
select throws_ok($$
  select public.claim_legacy_whatsapp_automation_v1(
    '55550000-0000-0000-0000-000000000001', 'INVALID', '919800000000', 'so_confirmation')
$$, '22023');
select throws_ok($$
  select public.claim_legacy_whatsapp_automation_v1(
    '55550000-0000-0000-0000-000000000001', 'so_created', 'invalid', 'so_confirmation')
$$, '22023');

-- Even a correctly authenticated service-only caller may not send for a missing order.
select throws_ok($
  select public.claim_legacy_whatsapp_automation_v1(
    '55550000-0000-0000-0000-000000000001', 'so_created', '919800000000', 'so_confirmation')
$, '23503');

select * from finish();
rollback;
