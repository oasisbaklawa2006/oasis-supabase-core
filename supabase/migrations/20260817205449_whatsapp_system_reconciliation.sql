-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010600_whatsapp_system_reconciliation.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Permit trusted system processing to detect zero-loss WhatsApp reconciliation
-- exceptions without impersonating a human operator. System runs may create/own
-- an OPERATIONS triage exception, but only an authenticated human with wa.intake.close
-- may resolve exceptions or sign a reconciliation run off.

alter table public.whatsapp_reconciliation_runs
  add column if not exists reconciled_actor_type text not null default 'OPERATOR';

alter table public.whatsapp_reconciliation_runs
  alter column reconciled_by drop not null;

alter table public.whatsapp_reconciliation_runs
  drop constraint if exists whatsapp_reconciliation_runs_actor_shape;
alter table public.whatsapp_reconciliation_runs
  add constraint whatsapp_reconciliation_runs_actor_shape check (
    (reconciled_actor_type='OPERATOR' and reconciled_by is not null)
    or (reconciled_actor_type='SYSTEM' and reconciled_by is null)
  );

alter table public.whatsapp_reconciliation_runs
  drop constraint if exists whatsapp_reconciliation_runs_actor_type_check;
alter table public.whatsapp_reconciliation_runs
  add constraint whatsapp_reconciliation_runs_actor_type_check
  check (reconciled_actor_type in ('OPERATOR','SYSTEM'));

alter table public.whatsapp_reconciliation_exceptions
  add column if not exists owner_team text;

update public.whatsapp_reconciliation_exceptions
set owner_team=coalesce(owner_team,'OPERATIONS')
where owner_team is null;

alter table public.whatsapp_reconciliation_exceptions
  alter column owner_id drop not null;

alter table public.whatsapp_reconciliation_exceptions
  drop constraint if exists whatsapp_reconciliation_exception_owner_shape;
alter table public.whatsapp_reconciliation_exceptions
  add constraint whatsapp_reconciliation_exception_owner_shape check (
    owner_id is not null or nullif(btrim(coalesce(owner_team,'')),'') is not null
  );

create or replace function public.whatsapp_run_system_reconciliation(
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_shift_code text,
  p_exception_due_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_role text:=coalesce(auth.jwt()->>'role','');
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_shift text:=upper(btrim(coalesce(p_shift_code,'')));
  v_run public.whatsapp_reconciliation_runs%rowtype;
  v_raw integer:=0;
  v_fragments integer:=0;
  v_cases integer:=0;
  v_orphans integer:=0;
  v_duplicates integer:=0;
  v_unresolved integer:=0;
  v_status text;
  r record;
begin
  if v_role<>'service_role' then
    raise exception 'trusted system reconciliation processor required' using errcode='42501';
  end if;
  if p_window_start is null or p_window_end is null or p_window_end<=p_window_start then raise exception 'valid reconciliation window required'; end if;
  if p_window_end>statement_timestamp()+interval '5 minutes' then raise exception 'reconciliation window cannot materially extend into the future'; end if;
  if p_window_end-p_window_start>interval '24 hours' then raise exception 'system reconciliation window cannot exceed 24 hours'; end if;
  if v_shift='' or length(v_shift)>80 then raise exception 'shift code required'; end if;
  if p_exception_due_at is null or p_exception_due_at<=statement_timestamp() then raise exception 'future exception due time required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_run
  from public.whatsapp_reconciliation_runs
  where correlation_key='system-reconcile:'||v_key;
  if found then return to_jsonb(v_run)||jsonb_build_object('idempotent_replay',true); end if;

  select count(*) into v_raw
  from public.whatsapp_inbound_messages i
  where i.received_at>=p_window_start and i.received_at<p_window_end;

  select count(*) into v_fragments
  from public.whatsapp_messages m
  where lower(m.direction)='inbound'
    and m.message_timestamp>=p_window_start at time zone 'UTC'
    and m.message_timestamp<p_window_end at time zone 'UTC'
    and m.packet_id is not null;

  select count(distinct c.id) into v_cases
  from public.whatsapp_communication_cases c
  join public.whatsapp_message_packets p on p.id=c.packet_id
  where p.first_message_at<p_window_end at time zone 'UTC'
    and p.last_message_at>=p_window_start at time zone 'UTC';

  select count(*) into v_orphans
  from public.whatsapp_inbound_messages i
  where i.received_at>=p_window_start and i.received_at<p_window_end
    and not exists(
      select 1 from public.whatsapp_messages m
      where m.provider_message_id=i.provider_message_id and lower(m.direction)='inbound'
    );

  select greatest(v_fragments-count(distinct m.provider_message_id),0) into v_duplicates
  from public.whatsapp_messages m
  where lower(m.direction)='inbound'
    and m.message_timestamp>=p_window_start at time zone 'UTC'
    and m.message_timestamp<p_window_end at time zone 'UTC'
    and m.packet_id is not null;

  select count(*) into v_unresolved
  from public.whatsapp_message_packets p
  where p.first_message_at<p_window_end at time zone 'UTC'
    and p.last_message_at>=p_window_start at time zone 'UTC'
    and not exists(select 1 from public.whatsapp_communication_cases c where c.packet_id=p.id);

  v_status:=case when v_orphans=0 and v_unresolved=0 then 'ALIGNED' else 'EXCEPTIONS_OPEN' end;

  insert into public.whatsapp_reconciliation_runs(
    window_start,window_end,shift_code,raw_message_count,packet_fragment_count,case_source_count,
    orphan_message_count,duplicate_count,unresolved_count,status,reconciled_by,reconciled_actor_type,correlation_key
  ) values(
    p_window_start,p_window_end,v_shift,v_raw,v_fragments,v_cases,v_orphans,v_duplicates,v_unresolved,
    v_status,null,'SYSTEM','system-reconcile:'||v_key
  ) returning * into v_run;

  for r in
    select i.id,i.provider_message_id
    from public.whatsapp_inbound_messages i
    where i.received_at>=p_window_start and i.received_at<p_window_end
      and not exists(select 1 from public.whatsapp_messages m where m.provider_message_id=i.provider_message_id and lower(m.direction)='inbound')
  loop
    insert into public.whatsapp_reconciliation_exceptions(
      reconciliation_run_id,exception_type,business_object_type,business_object_id,details,owner_id,owner_team,due_at
    ) values(
      v_run.id,'ORPHAN_RAW_MESSAGE','whatsapp_inbound_messages',r.id,
      jsonb_build_object('provider_message_id',r.provider_message_id,'detected_by','SYSTEM'),null,'OPERATIONS',p_exception_due_at
    );
  end loop;

  for r in
    select p.id
    from public.whatsapp_message_packets p
    where p.first_message_at<p_window_end at time zone 'UTC'
      and p.last_message_at>=p_window_start at time zone 'UTC'
      and not exists(select 1 from public.whatsapp_communication_cases c where c.packet_id=p.id)
  loop
    insert into public.whatsapp_reconciliation_exceptions(
      reconciliation_run_id,exception_type,business_object_type,business_object_id,details,owner_id,owner_team,due_at
    ) values(
      v_run.id,'PACKET_WITHOUT_CASE','whatsapp_message_packets',r.id,
      jsonb_build_object('window_start',p_window_start,'window_end',p_window_end,'detected_by','SYSTEM'),null,'OPERATIONS',p_exception_due_at
    );
  end loop;

  return to_jsonb(v_run)||jsonb_build_object('idempotent_replay',false,'human_signoff_required',true);
end;
$$;

comment on function public.whatsapp_run_system_reconciliation(timestamptz,timestamptz,text,timestamptz,text) is
  'Service-role-only zero-loss detector. It may create SYSTEM reconciliation runs and OPERATIONS-owned exceptions, but cannot resolve or sign them off.';
revoke all on function public.whatsapp_run_system_reconciliation(timestamptz,timestamptz,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.whatsapp_run_system_reconciliation(timestamptz,timestamptz,text,timestamptz,text) to service_role;
