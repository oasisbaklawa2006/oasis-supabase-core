-- Supervisory gate for task ownership overrides (Core PR #451 owner policy).
--
-- Owner direction: ordinary support executives keep claiming and completing eligible tasks; assigning,
-- reassigning and releasing someone else's task is limited to explicitly authorised supervisory roles; every
-- override needs a recorded reason (20261024136000). Production permission GRANTS are NOT changed here.
--
-- Supervisory roles are an explicit, reviewable allowlist in whatsapp_ownership_supervisor_role_keys().
-- A caller must ALSO hold wa.intake.assign, so permission, deny rules and active-user checks still apply.
-- Role-impact audit (read-only production data, 2026-10-24): wa.intake.assign is held via global roles by
-- support_executive (12 active users), super_admin (5) and admin (4); no deny rules, no scoped-role holders, no
-- user holds more than one of these roles. The allowlist ('admin','super_admin') covers 9 users. The ownership
-- functions are not yet in production, so no existing capability is removed.
--
-- Proposed (NOT enabled): require step-up (AAL2) for overrides, e.g. add `and public.has_step_up_auth()` to
-- whatsapp_is_ownership_supervisor() or register a high_risk permission with requires_step_up. That changes who
-- can act without MFA, so it needs an owner decision.
--
-- department membership is deliberately NOT used: users.department is blank for most operators.
-- Rollback: re-apply the function bodies from 20261024136000 and drop the two helpers below.

create or replace function public.whatsapp_ownership_supervisor_role_keys()
returns text[]
language sql
immutable
set search_path = pg_catalog
as $$ select array['admin','super_admin']::text[] $$;

-- Answers only for the calling user. Used by the ownership RPCs and by the work queue UI to decide
-- which buttons to offer (the RPCs re-check on every call).
create or replace function public.whatsapp_is_ownership_supervisor()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  select auth.uid() is not null
    and public.has_whatsapp_permission('wa.intake.assign')
    and exists (
      select 1
      from (
        select r.role_key
        from public.user_role_map urm
        join public.roles r on r.id = urm.role_id
        where urm.user_id = auth.uid() and coalesce(r.is_active, true)
        union
        select mr.role_key
        from public.org_memberships m
        join public.org_membership_roles mr on mr.membership_id = m.id
        where m.user_id = auth.uid() and m.status = 'active'
          and m.valid_from <= now() and (m.valid_until is null or m.valid_until > now())
      ) held
      where held.role_key = any (public.whatsapp_ownership_supervisor_role_keys())
    )
$$;

revoke all on function public.whatsapp_ownership_supervisor_role_keys() from public, anon, authenticated;
revoke all on function public.whatsapp_is_ownership_supervisor() from public, anon;
grant execute on function public.whatsapp_is_ownership_supervisor() to authenticated;

comment on function public.whatsapp_is_ownership_supervisor() is
  'True for the calling user only when they hold wa.intake.assign AND a role in whatsapp_ownership_supervisor_role_keys().';

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
      or exists (select 1 from public.whatsapp_case_department_tasks t where t.assigned_user_id = u.id)
    )
  order by 2;
end;
$$;


comment on function public.whatsapp_assign_case_task(uuid, uuid, text, text) is
  'Governed assign/reassign: ownership supervisors only (wa.intake.assign + allowlisted role); assignee must be an active wa.intake.triage user; taking a task from another owner requires a reason and is flagged override in the audit event.';
comment on function public.whatsapp_release_case_task(uuid, text, text) is
  'Return a task to the shared queue: the owner, or an ownership supervisor with a mandatory reason when overriding another owner; audited.';
comment on function public.whatsapp_case_staff_directory() is
  'Owner names for the work queue. Non-supervisors see only operators who own a task (and themselves); ownership supervisors see all eligible operators with department. No email or phone.';

revoke all on function public.whatsapp_assign_case_task(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_release_case_task(uuid, text, text) from public, anon, authenticated;
revoke all on function public.whatsapp_case_staff_directory() from public, anon, authenticated;
grant execute on function public.whatsapp_assign_case_task(uuid, uuid, text, text) to authenticated;
grant execute on function public.whatsapp_release_case_task(uuid, text, text) to authenticated;
grant execute on function public.whatsapp_case_staff_directory() to authenticated;
