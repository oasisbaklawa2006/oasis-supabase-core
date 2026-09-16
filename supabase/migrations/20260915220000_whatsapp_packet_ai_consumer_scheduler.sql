-- Contract coverage: 20260915220000_whatsapp_packet_ai_consumer_scheduler.sql
-- Durable WhatsApp packet AI consumer authority + fail-closed scheduler.
-- The scheduler remains inert until an environment-specific HTTPS consumer URL
-- is provisioned in Vault as whatsapp_packet_ai_consumer_url_v1.
begin;

-- Each environment gets its own generated machine secret. The value never
-- enters Git or cron.job and is compared only inside this service-role RPC.
do $$
begin
  if not exists (
    select 1
    from vault.decrypted_secrets
    where name = 'whatsapp_packet_ai_consumer_v1'
  ) then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'whatsapp_packet_ai_consumer_v1',
      'Machine-only secret for governed WhatsApp packet AI consumer execution'
    );
  end if;
end
$$;

create or replace function public.verify_whatsapp_packet_ai_consumer_secret(
  _candidate text
)
returns boolean
language sql
stable
security definer
set search_path = public, vault, pg_temp
as $$
  select coalesce(
    length(coalesce(_candidate, '')) >= 32
    and _candidate = (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'whatsapp_packet_ai_consumer_v1'
      order by created_at desc
      limit 1
    ),
    false
  );
$$;
revoke all on function public.verify_whatsapp_packet_ai_consumer_secret(text)
  from public, anon, authenticated;
grant execute on function public.verify_whatsapp_packet_ai_consumer_secret(text)
  to service_role;

-- Database-owner-only cron target. It intentionally does nothing until a
-- governed environment-specific URL is present. No service-role key or provider
-- credential is stored in the cron definition.
create or replace function public.whatsapp_run_packet_ai_consumer_tick()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, vault, pg_temp
as $$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return jsonb_build_object('status', 'disabled', 'reason', 'pg_net_missing');
  end if;

  select decrypted_secret
    into v_url
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_url_v1'
  order by created_at desc
  limit 1;

  select decrypted_secret
    into v_secret
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_v1'
  order by created_at desc
  limit 1;

  if coalesce(btrim(v_url), '') = '' then
    return jsonb_build_object('status', 'disabled', 'reason', 'consumer_url_missing');
  end if;
  if coalesce(btrim(v_secret), '') = '' then
    return jsonb_build_object('status', 'disabled', 'reason', 'consumer_secret_missing');
  end if;
  if v_url !~ '^https://[^[:space:]]+/functions/v1/whatsapp-packet-ai-consumer$' then
    return jsonb_build_object('status', 'disabled', 'reason', 'consumer_url_invalid');
  end if;

  execute $sql$
    select net.http_post(
      url := $1,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-oasis-worker-secret', $2
      ),
      body := jsonb_build_object('max_jobs', 3),
      timeout_milliseconds := 120000
    )
  $sql$
  into v_request_id
  using v_url, v_secret;

  return jsonb_build_object(
    'status', 'submitted',
    'request_id', v_request_id
  );
exception when others then
  -- Cron must fail closed without leaking the URL or secret into errors.
  return jsonb_build_object(
    'status', 'error',
    'sqlstate', sqlstate
  );
end;
$$;
revoke all on function public.whatsapp_run_packet_ai_consumer_tick()
  from public, anon, authenticated, service_role;

comment on function public.verify_whatsapp_packet_ai_consumer_secret(text) is
  'Service-role-only verifier for the Vault-backed WhatsApp packet AI consumer machine secret.';
comment on function public.whatsapp_run_packet_ai_consumer_tick() is
  'Database-owner-only fail-closed scheduler target for the durable WhatsApp packet AI outbox; inert until a governed consumer URL is provisioned in Vault.';

do $$
declare
  v_jobid bigint;
begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    select jobid
      into v_jobid
    from cron.job
    where jobname = 'whatsapp-packet-ai-consumer-minute'
    limit 1;
    if v_jobid is not null then
      perform cron.unschedule(v_jobid);
    end if;
    perform cron.schedule(
      'whatsapp-packet-ai-consumer-minute',
      '* * * * *',
      'select public.whatsapp_run_packet_ai_consumer_tick();'
    );
  end if;
end
$$;

commit;
