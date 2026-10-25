-- Core #452: enforce task-owner completion and task-scoped completion idempotency.
--
-- Defects reproduced on a clean replay of Core main (2a07222), each with the stock public.whatsapp_complete_case_task:
--  1. Ownership bypass: any wa.intake.triage operator could complete a task owned by a colleague, or an unowned
--     task, which defeats the claim/ownership model released in #451 (the Central queue only hides the button).
--  2. Cross-task replay: idempotency used (case_id, key). Reusing a key on a second task of the same case returned
--     idempotent_replay=true although that task was never completed (false success).
--  3. Duplicate completion audit: a fresh key on an already COMPLETED task inserted another DEPARTMENT_TASK_COMPLETED
--     event although nothing changed.
--
-- Policy (owner policy for #451, applied without new authority):
--  * Only the current owner (assigned_user_id) may complete a task. wa.intake.triage is still required.
--  * Unassigned and other-owned tasks are rejected with errcode 42501 and change nothing. A supervisor who needs to
--    finish someone else's task uses the existing audited path: whatsapp_assign_case_task (supervisor-gated, reason
--    required, override flagged) and then completes as owner. No implicit supervisor completion is introduced.
--  * wa.intake.assign grants, step-up/AAL2 settings and the supervisor allowlist are not touched.
--
-- Idempotency:
--  * New event correlation key: task-complete-v2:<task_id>:<key>. The distinct prefix guarantees it can never equal a
--    legacy task-complete:<caller key> value (a legacy caller key shaped <task_id>:<key> would otherwise collide with it
--    and, because of the per-case unique (case_id, correlation_key), block the legitimate event).
--  * Replay is recognised only for the SAME task and the SAME caller: the event's resulting_state.task_id must be this
--    task, whether it carries the new key or a legacy task-complete:<key>. A legacy event for another task is never
--    reinterpreted. A different caller reusing a key does not get a replay; they fall through to the ownership checks.
--  * Completing an already COMPLETED task with a new key raises CASE_TASK_ALREADY_COMPLETED and writes nothing, so the
--    append-only log is no longer padded with misleading completion events. Exact replay still returns the original result.
--
-- Signature, grants and return shape are unchanged. create or replace only; no table, trigger, data or grant change.
-- Rollback is forward-only and must NOT restore the previous body from 20260817193859 (it reintroduces the three defects
-- above). To change behaviour, ship a new migration that keeps the owner gate and task-scoped idempotency. To stop
-- completions entirely in an emergency, a new migration may revoke execute on this function from authenticated
-- (claim, assign and release are unaffected) until a corrected version is released through the protected workflow.
-- Completed tasks and audit events written by this version remain valid.

create or replace function public.whatsapp_complete_case_task(
  p_task_id uuid,
  p_response_payload jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_task public.whatsapp_case_department_tasks%rowtype;
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_event_key text;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode = '42501';
  end if;
  if p_response_payload is null or jsonb_typeof(p_response_payload) <> 'object' or p_response_payload = '{}'::jsonb then
    raise exception 'task response payload required';
  end if;
  if v_key = '' or length(v_key) > 160 then raise exception 'idempotency key required'; end if;

  select * into v_task from public.whatsapp_case_department_tasks where id = p_task_id for update;
  if not found then raise exception 'case task not found'; end if;

  v_event_key := 'task-complete-v2:' || v_task.id || ':' || v_key;

  -- Safe replay: same task, same caller; the event must name this very task whichever key format it carries.
  if exists (
    select 1
    from public.whatsapp_case_events e
    where e.case_id = v_task.case_id
      and e.event_type = 'DEPARTMENT_TASK_COMPLETED'
      and e.actor_id = v_actor
      and e.resulting_state ->> 'task_id' = v_task.id::text
      and (e.correlation_key = v_event_key or e.correlation_key = 'task-complete:' || v_key)
  ) then
    return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
      'idempotent_replay', true);
  end if;

  if v_task.status = 'CANCELLED' then raise exception 'cancelled case task cannot be completed'; end if;
  if v_task.status = 'COMPLETED' then
    raise exception 'CASE_TASK_ALREADY_COMPLETED: case task is already completed';
  end if;

  if v_task.assigned_user_id is null then
    raise exception 'CASE_TASK_NOT_CLAIMED: claim the task before completing it' using errcode = '42501';
  end if;
  if v_task.assigned_user_id <> v_actor then
    raise exception 'CASE_TASK_NOT_OWNER: only the task owner can complete it' using errcode = '42501';
  end if;

  update public.whatsapp_case_department_tasks
  set status = 'COMPLETED',
      response_payload = p_response_payload,
      completed_by = v_actor,
      completed_at = statement_timestamp(),
      updated_at = statement_timestamp()
  where id = v_task.id returning * into v_task;

  insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
  values (v_task.case_id, 'DEPARTMENT_TASK_COMPLETED', v_actor, 'OPERATOR', v_event_key,
    jsonb_build_object('task_id', v_task.id, 'department', v_task.department, 'status', 'COMPLETED',
      'assigned_user_id', v_task.assigned_user_id),
    p_response_payload);

  return jsonb_build_object('task_id', v_task.id, 'case_id', v_task.case_id, 'status', v_task.status,
    'idempotent_replay', false);
end;
$$;

comment on function public.whatsapp_complete_case_task(uuid, jsonb, text) is
  'Complete a department task: wa.intake.triage and the current owner only (claim first); task-scoped, caller-bound idempotency; completing a finished task raises CASE_TASK_ALREADY_COMPLETED without a new event.';

revoke all on function public.whatsapp_complete_case_task(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.whatsapp_complete_case_task(uuid, jsonb, text) to authenticated;
