-- Forward hardening of 20261024135000_whatsapp_case_task_ownership_v1.sql (Core PR #451 audit).
--
-- Why a new file: Supabase Preview only applies NEW migration files, and the preview branch already
-- applied the first version of 20261024135000. Editing it again would leave the preview stale.
-- Final state after both files is identical for replay and production (create or replace only).
--
-- Findings fixed (read-only production evidence, 2026-10-24):
--  1. wa.intake.assign is held by support_executive (12 active users) as well as admin and super_admin,
--     with no step-up. An assigner could silently take over or release a colleague's claimed task,
--     which bypasses the claim-conflict protection. Overriding another user's ownership now requires a
--     recorded reason and is flagged as an override in the audit event.
--  2. whatsapp_case_staff_directory() returned every eligible operator (name + department) to any
--     wa.intake.read holder. Readers now see only operators who currently own a task (needed to show
--     owner names); the full eligible list and departments are limited to wa.intake.assign holders.

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
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp assignment permission required' using errcode = '42501';
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
    where case_id = v_task.case_id and correlation_key = 'task-assign:' || v_key
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
    values (v_task.case_id, 'DEPARTMENT_TASK_ASSIGNED', v_actor, 'OPERATOR', 'task-assign:' || v_key,
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
    where case_id = v_task.case_id and correlation_key = 'task-release:' || v_key
  ) then
    return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
      'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', true);
  end if;

  if v_task.status in ('COMPLETED', 'CANCELLED') then
    raise exception 'CASE_TASK_NOT_RELEASABLE: task is %', lower(v_task.status);
  end if;
  if v_task.assigned_user_id is distinct from v_actor
     and not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'only the task owner or an assigner can release a task' using errcode = '42501';
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
    values (v_task.case_id, 'DEPARTMENT_TASK_RELEASED', v_actor, 'OPERATOR', 'task-release:' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', null),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', v_previous, 'reason', v_reason,
        'override', v_override));
  end if;

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', false);
end;
$$;

-- Owner lookups for the directory below.
create index if not exists whatsapp_case_department_tasks_assigned_user_idx
  on public.whatsapp_case_department_tasks (assigned_user_id)
  where assigned_user_id is not null;

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
  v_assigner := public.has_whatsapp_permission('wa.intake.assign');
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
      or exists (select 1 from public.whatsapp_case_department_tasks t where t.assigned_user_id = u.id)
    )
  order by 2;
end;
$$;

comment on function public.whatsapp_case_staff_directory() is
  'Owner names for the work queue. Readers see only operators who own a task; wa.intake.assign holders see all eligible operators with department. No email or phone.';
comment on function public.whatsapp_assign_case_task(uuid, uuid, text, text) is
  'Governed assign/reassign: wa.intake.assign; assignee must be an active wa.intake.triage user; taking a task from another owner requires a reason and is flagged override in the audit event.';
comment on function public.whatsapp_release_case_task(uuid, text, text) is
  'Return a task to the shared queue: owner, or wa.intake.assign with a mandatory reason when overriding another owner; audited.';

revoke all on function public.whatsapp_assign_case_task(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_release_case_task(uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_case_staff_directory() from public, anon, authenticated;
grant execute on function public.whatsapp_assign_case_task(uuid, uuid, text, text) to authenticated;
grant execute on function public.whatsapp_release_case_task(uuid, text, text) to authenticated;
grant execute on function public.whatsapp_case_staff_directory() to authenticated;
