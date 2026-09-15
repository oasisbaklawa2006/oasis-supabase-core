-- Contract coverage for 20260915093000_whatsapp_packet_ai_consumer_scheduler.sql.
begin;
select plan(11);

select ok(
  exists(
    select 1
    from vault.decrypted_secrets
    where name = 'whatsapp_packet_ai_consumer_v1'
      and length(decrypted_secret) >= 32
  ),
  'consumer machine secret is generated in Vault'
);

select is(
  (select count(*)::integer
   from vault.decrypted_secrets
   where name = 'whatsapp_packet_ai_consumer_url_v1'),
  0,
  'migration never auto-provisions an environment URL or activates outbound execution'
);

select has_function(
  'public',
  'verify_whatsapp_packet_ai_consumer_secret',
  array['text'],
  'consumer Vault secret verifier exists'
);

select function_privs_are(
  'public',
  'verify_whatsapp_packet_ai_consumer_secret',
  array['text'],
  'anon',
  array[]::text[],
  'anon cannot execute consumer secret verifier'
);

select function_privs_are(
  'public',
  'verify_whatsapp_packet_ai_consumer_secret',
  array['text'],
  'authenticated',
  array[]::text[],
  'authenticated cannot execute consumer secret verifier'
);

select function_privs_are(
  'public',
  'verify_whatsapp_packet_ai_consumer_secret',
  array['text'],
  'service_role',
  array['EXECUTE'],
  'service role can verify the machine secret inside the Edge consumer'
);

select has_function(
  'public',
  'whatsapp_run_packet_ai_consumer_tick',
  array[]::text[],
  'database-owned durable consumer scheduler target exists'
);

select function_privs_are(
  'public',
  'whatsapp_run_packet_ai_consumer_tick',
  array[]::text[],
  'anon',
  array[]::text[],
  'anon cannot invoke the scheduler target'
);

select function_privs_are(
  'public',
  'whatsapp_run_packet_ai_consumer_tick',
  array[]::text[],
  'authenticated',
  array[]::text[],
  'authenticated cannot invoke the scheduler target'
);

select function_privs_are(
  'public',
  'whatsapp_run_packet_ai_consumer_tick',
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
    where jobname = 'whatsapp-packet-ai-consumer-minute'
      and schedule = '* * * * *'
      and command = 'select public.whatsapp_run_packet_ai_consumer_tick();'
  ),
  'pg_cron installs exactly the guarded minute consumer schedule when available'
);

select * from finish();
rollback;
