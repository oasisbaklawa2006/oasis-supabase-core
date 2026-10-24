-- WhatsApp UI/UX simplification (Central #639 / PR #640, ASM-06 / Central #638):
-- governed shared-queue ownership for department case tasks.
--
-- Adds claim / assign-reassign / release over public.whatsapp_case_department_tasks.
-- No table, column or existing function is changed; nothing is auto-assigned and no
-- historical row is touched. Rollback: drop the three functions (see the pgTAP header).
--
-- Authority is unchanged and reused: has_whatsapp_permission() already enforces active
-- identity, role grants and AAL2 for step-up permissions. Every state change is recorded
-- as an append-only whatsapp_case_events row keyed by the caller's idempotency key.

-- has_app_permission() evaluates only the calling identity (or service_role), so an assigner
-- cannot use it on someone else. This internal helper answers one narrow question for the
-- assignment guard: may this ACTIVE user work WhatsApp triage tasks? It mirrors the role
-- resolution of has_app_permission for the non-step-up key wa.intake.triage (deny wins,
-- super_admin allowed). It is not granted to any API role.
create or replace function public.whatsapp_case_task_assignee_eligible(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  with roles_for_user as (
    select r.role_key
    from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = p_user_id and coalesce(r.is_active, true)
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
       exists (select 1 from roles_for_user where role_key = 'super_admin')
       or exists (select 1 from decisions where effect = 'allow')
     )
$$;

revoke all on function public.whatsapp_case_task_assignee_eligible(uuid) from public, anon, authenticated;

-- Minimal read model for owner names and the assign picker. `users` is readable only by
-- admins and self, so ordinary staff could not otherwise show who owns a task. Exposes
-- display name and department of ACTIVE triage-capable staff only (no email/phone).
create or replace function public.whatsapp_case_staff_directory()
returns table(user_id uuid, display_name text, department text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  if auth.uid() is null or not public.has_whatsapp_permission('wa.intake.read') then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;
  return query
  select u.id,
         coalesce(nullif(btrim(u.full_name), ''), nullif(btrim(u.name), ''), 'Staff ' || left(u.id::text, 8)),
         nullif(btrim(u.department), '')
  from public.users u
  where coalesce(u.is_active, true) and u.deleted_at is null
    and public.whatsapp_case_task_assignee_eligible(u.id)
  order by 2;
end;
$$;

comment on function public.whatsapp_case_staff_directory() is
  'Read-only directory of active WhatsApp triage staff (name, department) for task owner display and assignment.';
revoke all on function public.whatsapp_case_staff_directory() from public, anon, authenticated;
grant execute on function public.whatsapp_case_staff_directory() to authenticated;

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
    where case_id = v_task.case_id and correlation_key = 'task-claim:' || v_key
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
    values (v_task.case_id, 'DEPARTMENT_TASK_CLAIMED', v_actor, 'OPERATOR', 'task-claim:' || v_key,
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
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp assignment permission required' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;
  if v_reason is not null and length(v_reason) > 500 then raise exception 'reason too long'; end if;
  if p_assignee_user_id is null then raise exception 'assignee required'; end if;

  -- The assignee must be an active, non-deleted user who can actually work the task.
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
  if v_previous is distinct from p_assignee_user_id then
    update public.whatsapp_case_department_tasks
    set assigned_user_id = p_assignee_user_id
    where id = v_task.id returning * into v_task;

    insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
    values (v_task.case_id, 'DEPARTMENT_TASK_ASSIGNED', v_actor, 'OPERATOR', 'task-assign:' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', p_assignee_user_id),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', v_previous, 'reason', v_reason));
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
  -- Only the current owner may hand a task back; managers use assign.
  if v_task.assigned_user_id is distinct from v_actor
     and not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'only the task owner or an assigner can release a task' using errcode = '42501';
  end if;

  v_previous := v_task.assigned_user_id;
  if v_previous is not null then
    update public.whatsapp_case_department_tasks
    set assigned_user_id = null,
        status = case when status = 'IN_PROGRESS' then 'OPEN' else status end
    where id = v_task.id returning * into v_task;

    insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
    values (v_task.case_id, 'DEPARTMENT_TASK_RELEASED', v_actor, 'OPERATOR', 'task-release:' || v_key,
      jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', v_task.status,
        'assigned_user_id', null),
      jsonb_build_object('task_id', v_task.id, 'previous_assigned_user_id', v_previous, 'reason', v_reason));
  end if;

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'assigned_user_id', v_task.assigned_user_id, 'idempotent_replay', false);
end;
$$;

comment on function public.whatsapp_claim_case_task(uuid, text) is
  'Governed shared-queue claim: wa.intake.triage; row-locked so only one claimant wins; idempotent; audited in whatsapp_case_events.';
comment on function public.whatsapp_assign_case_task(uuid, uuid, text, text) is
  'Governed assign/reassign: wa.intake.assign; assignee must be an active wa.intake.triage user; previous owner recorded in the audit event.';
comment on function public.whatsapp_release_case_task(uuid, text, text) is
  'Return a task to the shared queue: owner or wa.intake.assign; idempotent; audited.';

revoke all on function public.whatsapp_claim_case_task(uuid, text) from public, anon, authenticated;
revoke all on function public.whatsapp_assign_case_task(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_release_case_task(uuid, text, text) from public, anon, authenticated;
grant execute on function public.whatsapp_claim_case_task(uuid, text) to authenticated;
grant execute on function public.whatsapp_assign_case_task(uuid, uuid, text, text) to authenticated;
grant execute on function public.whatsapp_release_case_task(uuid, text, text) to authenticated;
