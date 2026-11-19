-- CI-only scratch database: fixed consent timestamp replay across committed transactions.
-- 20261119020050_gifting_enquiry_receiver_validation.sql. No token is printed.
BEGIN;
SET LOCAL TIME ZONE 'UTC';
DO $uat$
DECLARE c jsonb; t jsonb; b jsonb; receipt jsonb; lead uuid := gen_random_uuid();
BEGIN
 c := public.connect_admin_register_consumer_v1('gft557-review-'||replace(gen_random_uuid()::text,'-',''),'b2c_website','staging','PR557 synthetic replay');
 b := public.connect_admin_bind_profile_v1((c->>'consumer_id')::uuid,(select id from public.connect_profiles where profile_key='gifting_enquiries_v1'),'staging');
 t := public.connect_admin_issue_token_v1((c->>'consumer_id')::uuid,array['enquiries:gifting:write'],'staging',now()+interval '5 minutes');
 receipt := public.gifting_enquiry_receive_v1(t->>'token',lead,'{"kind":"contact","email":"review@example.invalid","source":"uat-synthetic-pr557-review","consent":{"marketing":false,"timestamp":"2026-11-19T00:00:00Z"}}'::jsonb);
 PERFORM set_config('gft557.token',t->>'token',false);
 PERFORM set_config('gft557.token_id',t->>'token_id',false);
 PERFORM set_config('gft557.consumer_id',c->>'consumer_id',false);
 PERFORM set_config('gft557.lead',lead::text,false);
 PERFORM set_config('gft557.receipt',receipt->>'enquiryId',false);
 PERFORM set_config('gft557.transaction_id',txid_current()::text,false);
END $uat$;
COMMIT;
BEGIN;
SET LOCAL TIME ZONE 'UTC';
DO $uat$
DECLARE receipt jsonb; verdict boolean := false;
BEGIN
 BEGIN
  receipt := public.gifting_enquiry_receive_v1(current_setting('gft557.token'),current_setting('gft557.lead')::uuid,'{"kind":"contact","email":"review@example.invalid","source":"uat-synthetic-pr557-review","consent":{"marketing":false,"timestamp":"2026-11-19T00:00:00Z"}}'::jsonb);
  verdict := receipt->>'enquiryId'=current_setting('gft557.receipt') AND receipt->>'replayed'='true' AND txid_current()::text<>current_setting('gft557.transaction_id');
 EXCEPTION WHEN others THEN verdict := false;
 END;
 PERFORM public.connect_admin_revoke_token_v1(current_setting('gft557.token_id')::uuid);
 DELETE FROM public.gifting_enquiries WHERE consumer_id=current_setting('gft557.consumer_id')::uuid AND source_lead_id=current_setting('gft557.lead')::uuid;
 DELETE FROM public.connect_tokens WHERE consumer_id=current_setting('gft557.consumer_id')::uuid;
 DELETE FROM public.connect_bindings WHERE consumer_id=current_setting('gft557.consumer_id')::uuid;
 DELETE FROM public.connect_consumers WHERE id=current_setting('gft557.consumer_id')::uuid;
 PERFORM set_config('gft557.cross_transaction_pass',verdict::text,false);
 PERFORM set_config('gft557.transactions_distinct',(txid_current()::text<>current_setting('gft557.transaction_id'))::text,false);
 PERFORM set_config('gft557.cleanup_pass', (NOT EXISTS(select 1 from public.connect_tokens where consumer_id=current_setting('gft557.consumer_id')::uuid and revoked_at is null))::text,false);
 PERFORM set_config('gft557.token','',false);
END $uat$;
COMMIT;
BEGIN;
SELECT plan(3);
SELECT ok(current_setting('gft557.cross_transaction_pass')::boolean, 'fixed ISO consent timestamp recovers the same receipt across transactions');
SELECT ok(current_setting('gft557.transactions_distinct')::boolean, 'delivery and replay used distinct committed transactions');
SELECT ok(current_setting('gft557.cleanup_pass')::boolean AND NOT EXISTS (SELECT 1 FROM public.connect_consumers WHERE id=current_setting('gft557.consumer_id')::uuid), 'synthetic credential and consumer fixtures removed');
SELECT * FROM finish();
ROLLBACK;
