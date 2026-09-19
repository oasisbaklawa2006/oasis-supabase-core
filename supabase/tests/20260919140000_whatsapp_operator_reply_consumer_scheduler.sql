-- Contract coverage for 20260919140000_whatsapp_operator_reply_consumer_scheduler.sql.
begin;
select plan(11);

select ok(
  exists(
    select 1
    from vault.decrypted_secrets
    where name = 'whatsapp_operator_reply_consumer_v1'
      and length(decrypted_secret) >= 32
  ),
  'operator-reply consumer machine secret is generated in Vault'
);

select is(
  (select count(*)::integer
   from vault.decrypted_secrets
   where name = 'whatsapp_operator_reply_consumer_url_v1'),
  0,
  'migration never auto-provisions an environment URL or activates outbound execution'
);

select has_function(
  'public',
  'verify_whatsapp_operator_reply_consumer_secret',
  array['text'],
  'operator-reply consumer Vault secret verifier exists'
);

select function_privs_are(
  'public',
  'verify_whatsapp_operator_reply_consumer_secret',
  array['text'],
  'anon',
  array[]::text[],
  'anon cannot execute operator-reply consumer secret verifier'
);

select function_privs_are(
  'public',
  'verify_whatsapp_operator_reply_consumer_secret',
  array['text'],
  'authenticated',
  array[]::text[],
  'authenticated cannot execute operator-reply consumer secret verifier'
);

select function_privs_are(
  'public',
  'verify_whatsapp_operator_reply_consumer_secret',
  array['text'],
  'service_role',
  array['EXECUTE'],
  'service role can verify the machine secret inside the Edge consumer'
);

select has_function(
  'public',
  'whatsapp_run_operator_reply_consumer_tick',
  array[]::text[],
  'database-owned durable operator-reply consumer scheduler target exists'
);

select function_privs_are(
  'public',
  'whatsapp_run_operator_reply_consumer_tick',
  array[]::text[],
  'anon',
  array[]::text[],
  'anon cannot invoke the operator-reply scheduler target'
);

select function_privs_are(
  'public',
  'whatsapp_run_operator_reply_consumer_tick',
  array[]::text[],
  'authenticated',
  array[]::text[],
  'authenticated cannot invoke the operator-reply scheduler target'
);

select function_privs_are(
  'public',
  'whatsapp_run_operator_reply_consumer_tick',
  array[]::text[],
  'service_role',
  array[]::text[],
  'service role cannot invoke the database-owner cron target directly'
);

select ok(
  not exists(select 1 from pg_extension where extname = 'pg_cron')
  or exists(
    select 1
    from cron.job
    where jobname = 'whatsapp-operator-reply-consumer-minute'
      and schedule = '* * * * *'
      and command = 'select public.whatsapp_run_operator_reply_consumer_tick();'
  ),
  'pg_cron installs exactly the guarded minute operator-reply consumer schedule when available'
);

select * from finish();
rollback;
