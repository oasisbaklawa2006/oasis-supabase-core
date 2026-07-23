-- Contract assertions for Point 21 notification infrastructure
begin;

select plan(1);

do $$
begin
  if to_regprocedure('public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz)') is null then
    raise exception 'enqueue_notification_v1 is missing';
  end if;
  if to_regprocedure('public.claim_notification_batch_v1(text,integer,integer)') is null then
    raise exception 'claim_notification_batch_v1 is missing';
  end if;
  if to_regprocedure('public.complete_notification_v1(uuid,text,text)') is null then
    raise exception 'complete_notification_v1 is missing';
  end if;
  if to_regprocedure('public.fail_notification_v1(uuid,text,text,integer)') is null then
    raise exception 'fail_notification_v1 is missing';
  end if;
end $$;

do $$
declare required_column text;
begin
  foreach required_column in array array[
    'source_application','channel','idempotency_key','event_id','attempt_count',
    'max_attempts','next_attempt_at','locked_at','locked_by','provider_message_id',
    'last_attempt_at','updated_at'
  ] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='notification_outbox' and column_name=required_column
    ) then
      raise exception 'notification_outbox.% is missing', required_column;
    end if;
  end loop;
end $$;

do $$
begin
  if has_function_privilege('anon','public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz)','EXECUTE') then
    raise exception 'anon can enqueue notifications';
  end if;
  if has_function_privilege('authenticated','public.claim_notification_batch_v1(text,integer,integer)','EXECUTE') then
    raise exception 'authenticated can claim notification batches';
  end if;
  if not has_function_privilege('service_role','public.claim_notification_batch_v1(text,integer,integer)','EXECUTE') then
    raise exception 'service_role cannot claim notification batches';
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and tablename='notification_outbox'
      and indexname='notification_outbox_source_idempotency_uidx'
  ) then
    raise exception 'notification idempotency index missing';
  end if;
end $$;

select ok(true, 'Point 21 notification infrastructure contract holds');
select * from finish();
rollback;
