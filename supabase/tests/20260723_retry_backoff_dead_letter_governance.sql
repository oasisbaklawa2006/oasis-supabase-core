begin;

select plan(1);

do $$
begin
  if to_regclass('public.retry_policies') is null then
    raise exception 'retry_policies missing';
  end if;
  if to_regclass('public.dead_letter_entries') is null then
    raise exception 'dead_letter_entries missing';
  end if;
  if to_regprocedure('public.calculate_retry_delay_v1(text,integer,text)') is null then
    raise exception 'calculate_retry_delay_v1 missing';
  end if;
  if to_regprocedure('public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)') is null then
    raise exception 'record_dead_letter_v1 missing';
  end if;
  if to_regprocedure('public.resolve_dead_letter_v1(uuid,text,text)') is null then
    raise exception 'resolve_dead_letter_v1 missing';
  end if;
end $$;

do $$
declare
  d1 integer;
  d2 integer;
  d20 integer;
begin
  d1 := public.calculate_retry_delay_v1('notification.delivery.default',1,'contract');
  d2 := public.calculate_retry_delay_v1('notification.delivery.default',2,'contract');
  d20 := public.calculate_retry_delay_v1('notification.delivery.default',20,'contract');
  if d1 < 0 or d2 <= d1 or d20 > 3600 then
    raise exception 'retry backoff contract failed';
  end if;
end $$;

do $$
begin
  if has_function_privilege('anon','public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)','EXECUTE') then
    raise exception 'anon can record dead letters';
  end if;
  if has_function_privilege('authenticated','public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)','EXECUTE') then
    raise exception 'authenticated can record dead letters';
  end if;
  if not has_function_privilege('service_role','public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb)','EXECUTE') then
    raise exception 'service_role cannot record dead letters';
  end if;
end $$;

select ok(true, 'Retry, backoff and dead-letter governance contract holds');
select * from finish();
rollback;
