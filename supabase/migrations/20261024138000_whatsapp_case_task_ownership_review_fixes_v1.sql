-- Review fixes for Core PR #451 (CodeRabbit "merge risk" findings, each checked against the code).
--
-- 1. Idempotency keys are now scoped to the task. Before, replay detection used (case_id, key), so reusing a key
--    on a sibling task in the same case returned idempotent_replay=true although that task was never claimed
--    (reproduced locally). Event correlation keys become task-<kind>:<task_id>:<key>.
-- 2. The staff directory no longer lists operators who only own FINISHED tasks to non-supervisors: only owners of
--    open, in-progress or blocked tasks (and the caller) are shown.
-- 3. The assignee eligibility helper applies the super_admin shortcut to GLOBAL roles only, exactly like
--    has_app_permission(). (Not a production difference today because super_admin also holds explicit grants;
--    aligned so the two cannot drift.)
--
-- Shipped as a NEW file because Supabase Preview applies only new migration files. create or replace only.
-- Rollback: re-apply the function bodies from 20261024135000 and 20261024137000.

create or replace function public.whatsapp_case_task_assignee_eligible(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  with global_roles as (
    select r.role_key
    from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = p_user_id and coalesce(r.is_active, true)
  ),
  roles_for_user as (
    select role_key from global_roles
    union
    select mr.role_key
    from public.org_memberships m
    join public.org_membership_roles mr on mr.membership_id = m.id
    where m.user_id = p_user_id and m.status = 'active'
      and m.valid_from <= now() and (m.valid_until is null or m.valid_until > now())
  ),
  decisions as (
    select g.effect
    from roles_for_user ar
    join public.role_permission_grants g on g.role_key = ar.role_key
    where g.permission_key = 'wa.intake.triage'
  )
  select exists (
           select 1 from public.users u
           where u.id = p_user_id and coalesce(u.is_active, true) and u.deleted_at is null
         )
     and exists (
           select 1 from public.access_permissions p
           where p.permission_key = 'wa.intake.triage' and p.is_active
         )
     and not exists (select 1 from decisions where effect = 'deny')
     and (
       -- exactly as has_app_permission(): the super_admin shortcut applies to GLOBAL roles only
       exists (select 1 from global_roles where role_key = 'super_admin')
       or exists (select 1 from decisions where effect = 'allow')
     )
$$;

create or replace function public.whatsapp_claim_case_task(
  p_task_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_task public.whatsapp_case_department_tasks%rowtype;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;

  select * into v_task from public.whatsapp_case_department_tasks where id = p_task_id for update;
  if not found then raise exception 'case task not found'; end if;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_task.case_id and correlation_key = 'task-claim:' || p_task_id::text || ':' || v_key
  ) then
    return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
      'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', true);
  end if;

  if v_task.status in ('COMPLETED', 'CANCELLED') then
    raise exception 'CASE_TASK_NOT_CLAIMABLE: task is %', lower(v_task.status);
  end if;
  if v_task.assigned_user_id is not null and v_task.assigned_user_id <> v_actor then
    raise exception 'CASE_TASK_ALREADY_CLAIMED' using errcode = '55P03';
  end if;

  if v_task.assigned_user_id is null then
    update public.whatsapp_case_department_tasks
    set assigned_user_id = v_actor,
        status = case when status = 'OPEN' then 'IN_PROGRESS' else status end
    where id = v_task.id returning * into v_task;

    insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
    values (v_task.case_id, 'DEPARTMENT_TASK_CLAIMED', v_actor, 'OPERATOR', 'task-claim:' || p_task_id::text || ':' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', v_actor),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', null));
  end if;

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', false);
end;
$$;

create or replace function public.whatsapp_assign_case_task(
  p_task_id uuid,
  p_assignee_user_id uuid,
  p_idempotency_key text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_task public.whatsapp_case_department_tasks%rowtype;
  v_previous uuid;
  v_override boolean;
begin
  if v_actor is null or not public.whatsapp_is_ownership_supervisor() then
    raise exception 'ownership supervisor role required to assign tasks' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;
  if v_reason is not null and length(v_reason) > 500 then raise exception 'reason too long'; end if;
  if p_assignee_user_id is null then raise exception 'assignee required'; end if;

  if not public.whatsapp_case_task_assignee_eligible(p_assignee_user_id) then
    raise exception 'assignee is not an active user with WhatsApp triage permission';
  end if;

  select * into v_task from public.whatsapp_case_department_tasks where id = p_task_id for update;
  if not found then raise exception 'case task not found'; end if;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_task.case_id and correlation_key = 'task-assign:' || p_task_id::text || ':' || v_key
  ) then
    return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
      'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', true);
  end if;

  if v_task.status in ('COMPLETED', 'CANCELLED') then
    raise exception 'CASE_TASK_NOT_ASSIGNABLE: task is %', lower(v_task.status);
  end if;

  v_previous := v_task.assigned_user_id;
  -- Changing the owner of a task somebody else holds is an override and must say why.
  v_override := v_previous is not null and v_previous <> v_actor and v_previous is distinct from p_assignee_user_id;
  if v_override and v_reason is null then
    raise exception 'CASE_TASK_OVERRIDE_REASON_REQUIRED: a reason is required to take a task away from its owner';
  end if;

  if v_previous is distinct from p_assignee_user_id then
    update public.whatsapp_case_department_tasks
    set assigned_user_id = p_assignee_user_id
    where id = v_task.id returning * into v_task;

    insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
    values (v_task.case_id, 'DEPARTMENT_TASK_ASSIGNED', v_actor, 'OPERATOR', 'task-assign:' || p_task_id::text || ':' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', p_assignee_user_id),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', v_previous, 'reason', v_reason,
        'override', v_override));
  end if;

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', false);
end;
$$;

create or replace function public.whatsapp_release_case_task(
  p_task_id uuid,
  p_idempotency_key text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_task public.whatsapp_case_department_tasks%rowtype;
  v_previous uuid;
  v_override boolean;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;
  if v_reason is not null and length(v_reason) > 500 then raise exception 'reason too long'; end if;

  select * into v_task from public.whatsapp_case_department_tasks where id = p_task_id for update;
  if not found then raise exception 'case task not found'; end if;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_task.case_id and correlation_key = 'task-release:' || p_task_id::text || ':' || v_key
  ) then
    return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
      'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', true);
  end if;

  if v_task.status in ('COMPLETED', 'CANCELLED') then
    raise exception 'CASE_TASK_NOT_RELEASABLE: task is %', lower(v_task.status);
  end if;
  if v_task.assigned_user_id is distinct from v_actor
     and not public.whatsapp_is_ownership_supervisor() then
    raise exception 'only the task owner or an ownership supervisor can release a task' using errcode = '42501';
  end if;

  v_previous := v_task.assigned_user_id;
  v_override := v_previous is not null and v_previous <> v_actor;
  if v_override and v_reason is null then
    raise exception 'CASE_TASK_OVERRIDE_REASON_REQUIRED: a reason is required to release a task owned by someone else';
  end if;

  if v_previous is not null then
    update public.whatsapp_case_department_tasks
    set assigned_user_id = null,
        status = case when status = 'IN_PROGRESS' then 'OPEN' else status end
    where id = v_task.id returning * into v_task;

    insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
    values (v_task.case_id, 'DEPARTMENT_TASK_RELEASED', v_actor, 'OPERATOR', 'task-release:' || p_task_id::text || ':' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', null),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', v_previous, 'reason', v_reason,
        'override', v_override));
  end if;

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', false);
end;
$$;

create or replace function public.whatsapp_case_staff_directory()
returns table(user_id uuid, display_name text, department text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_assigner boolean;
begin
  if auth.uid() is null or not public.has_whatsapp_permission('wa.intake.read') then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;
  v_assigner := public.whatsapp_is_ownership_supervisor();
  return query
  select u.id,
         coalesce(nullif(btrim(u.full_name), ''), nullif(btrim(u.name), ''), 'Staff ' || left(u.id::text, 8)),
         case when v_assigner then nullif(btrim(u.department), '') else null end
  from public.users u
  where coalesce(u.is_active, true) and u.deleted_at is null
    and public.whatsapp_case_task_assignee_eligible(u.id)
    and (
      v_assigner
      or u.id = auth.uid()
      or exists (
        select 1 from public.whatsapp_case_department_tasks t
        where t.assigned_user_id = u.id and t.status in ('OPEN', 'IN_PROGRESS', 'BLOCKED')
      )
    )
  order by 2;
end;
$$;

revoke all on function public.whatsapp_claim_case_task(uuid, text) from public, anon, authenticated;
revoke all on function public.whatsapp_assign_case_task(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_release_case_task(uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_case_staff_directory() from public, anon, authenticated;
revoke all on function public.whatsapp_case_task_assignee_eligible(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_claim_case_task(uuid, text) to authenticated;
grant execute on function public.whatsapp_assign_case_task(uuid, uuid, text, text) to authenticated;
grant execute on function public.whatsapp_release_case_task(uuid, text, text) to authenticated;
grant execute on function public.whatsapp_case_staff_directory() to authenticated;
