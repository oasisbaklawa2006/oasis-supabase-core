-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260817180100_whatsapp_b2b_case_routing_team_guard.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Forward-only hardening for 20260817180000_whatsapp_b2b_case_orchestration.sql.
-- Enforce the bounded current-phase B2B response-team vocabulary at Core.

create or replace function public.whatsapp_b2b_response_team_allowed(p_team text)
returns boolean
language sql
immutable
set search_path = pg_catalog, public
as $$
  select upper(btrim(coalesce(p_team, ''))) = any(array[
    'SALES','FINANCE','QUALITY','DISPATCH','LOGISTICS','PRODUCTION',
    'PACKAGING','OPERATIONS','CUSTOMER_SERVICE'
  ]::text[])
$$;

comment on function public.whatsapp_b2b_response_team_allowed(text) is
  'Canonical current-phase B2B WhatsApp response-team guard used by governed case routing.';

revoke all on function public.whatsapp_b2b_response_team_allowed(text) from public, anon, authenticated;
grant execute on function public.whatsapp_b2b_response_team_allowed(text) to service_role;

create or replace function public.whatsapp_accept_ai_case_routing(
  p_case_id uuid,
  p_accountable_team text,
  p_next_action text,
  p_due_at timestamptz,
  p_contributor_departments text[] default '{}'::text[],
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_team text := upper(btrim(coalesce(p_accountable_team, '')));
  v_action text := btrim(coalesce(p_next_action, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_department text;
  v_primary_task_id uuid;
begin
  if v_actor is null
     or not public.has_whatsapp_permission('wa.intake.triage')
     or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp triage and assignment permissions required' using errcode = '42501';
  end if;

  if not public.whatsapp_b2b_response_team_allowed(v_team) then
    raise exception 'unsupported WhatsApp accountable team';
  end if;
  if v_action = '' or length(v_action) > 1000 then raise exception 'next action required'; end if;
  if p_due_at is null or p_due_at <= statement_timestamp() then raise exception 'future due time required'; end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;
  if coalesce(cardinality(p_contributor_departments), 0) > 12 then raise exception 'too many contributor departments'; end if;
  if exists (
    select 1 from unnest(coalesce(p_contributor_departments, '{}'::text[])) d
    where not public.whatsapp_b2b_response_team_allowed(d)
  ) then
    raise exception 'unsupported WhatsApp contributor team';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed WhatsApp case cannot be assigned'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='ai-routing-accept:'||v_key) then
    return jsonb_build_object('case_id',v_case.id,'idempotent_replay',true,'accountable_team',v_case.accountable_team,
      'accountable_owner_id',v_case.accountable_owner_id,'status',v_case.status);
  end if;

  update public.whatsapp_communication_cases
  set accountable_team=v_team, accountable_owner_id=v_actor, accountability_status='ASSIGNED',
      assigned_at=statement_timestamp(), assigned_by=v_actor, next_action=v_action,
      next_action_due_at=p_due_at, updated_at=statement_timestamp()
  where id=p_case_id returning * into v_case;

  insert into public.whatsapp_case_department_tasks(case_id,department,assigned_user_id,task_type,instructions,status,due_at,correlation_key,created_by)
  values(p_case_id,v_team,v_actor,'ACCOUNTABLE_RESPONSE_OWNER',v_action,'OPEN',p_due_at,'ai-routing-primary:'||v_key,v_actor)
  on conflict(case_id,correlation_key) do nothing returning id into v_primary_task_id;

  foreach v_department in array coalesce(p_contributor_departments,'{}'::text[]) loop
    v_department:=upper(btrim(v_department));
    if v_department<>'' and v_department<>v_team then
      insert into public.whatsapp_case_department_tasks(case_id,department,assigned_user_id,task_type,instructions,status,due_at,correlation_key,created_by)
      values(p_case_id,v_department,null,'CASE_CONTRIBUTOR','Contribute facts/action required for accountable response: '||v_action,
        'OPEN',p_due_at,'ai-routing-contributor:'||v_key||':'||lower(v_department),v_actor)
      on conflict(case_id,correlation_key) do nothing;
    end if;
  end loop;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,prior_state,resulting_state,metadata)
  values(p_case_id,'AI_ROUTING_ACCEPTED',v_actor,'OPERATOR','ai-routing-accept:'||v_key,
    jsonb_build_object('accountable_team',null,'accountable_owner_id',null),
    jsonb_build_object('accountable_team',v_team,'accountable_owner_id',v_actor,'next_action',v_action,'due_at',p_due_at),
    jsonb_build_object('source','AI_DECISION_DESK','primary_task_id',v_primary_task_id,
      'contributor_departments',to_jsonb(coalesce(p_contributor_departments,'{}'::text[]))));

  return jsonb_build_object('case_id',v_case.id,'idempotent_replay',false,'accountable_team',v_case.accountable_team,
    'accountable_owner_id',v_case.accountable_owner_id,'next_action',v_case.next_action,
    'next_action_due_at',v_case.next_action_due_at,'primary_task_id',v_primary_task_id);
end;
$$;
