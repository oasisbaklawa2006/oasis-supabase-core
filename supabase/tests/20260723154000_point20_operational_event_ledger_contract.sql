-- Contract assertions for Point 20 operational event ledger
begin;

do $$
begin
  if to_regprocedure('public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz)') is null then
    raise exception 'append_operational_event_v1 is missing';
  end if;

  if has_function_privilege('anon', 'public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz)', 'EXECUTE') then
    raise exception 'anon can execute append_operational_event_v1';
  end if;
end $$;

do $$
declare
  required_column text;
begin
  foreach required_column in array array[
    'source_application','event_version','command_name','command_id',
    'causation_id','occurred_at','payload_fingerprint'
  ] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='operational_events' and column_name=required_column
    ) then
      raise exception 'operational_events.% is missing', required_column;
    end if;
  end loop;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and tablename='operational_events'
      and indexname='operational_events_source_idempotency_uidx'
  ) then
    raise exception 'source-scoped idempotency index is missing';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.operational_events'::regclass
      and tgname='trg_operational_events_no_update' and tgenabled <> 'D'
  ) or not exists (
    select 1 from pg_trigger
    where tgrelid='public.operational_events'::regclass
      and tgname='trg_operational_events_no_delete' and tgenabled <> 'D'
  ) then
    raise exception 'append-only triggers are missing or disabled';
  end if;
end $$;

rollback;
