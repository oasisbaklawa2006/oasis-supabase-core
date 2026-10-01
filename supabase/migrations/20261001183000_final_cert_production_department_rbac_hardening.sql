-- Final certification repair: close remaining cross-department production mutation paths.
-- Scope is deliberately limited to server-side authorization on existing RPCs.
-- No table/data rewrite and no authority broadening.

begin;

create or replace function public.dispatch_production_to_rgs(
  p_job_id uuid,
  p_dispatched_qty numeric,
  p_correlation_id text,
  p_destination_store_code text default 'FINISHED_GOODS'
)
returns public.production_rgs_transfers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%rowtype;
  v_transfer public.production_rgs_transfers%rowtype;
  v_product_sku text;
begin
  select role into v_actor_role from public.users where id = v_actor_id;
  if v_actor_id is null or not public.is_internal_staff(v_actor_id) then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if nullif(btrim(p_correlation_id), '') is null then
    raise exception 'A correlation id is required';
  end if;

  select * into v_transfer
  from public.production_rgs_transfers
  where correlation_id = p_correlation_id;
  if found then return v_transfer; end if;

  select * into v_job from public.production_jobs where id = p_job_id for update;
  if not found then raise exception 'Production job not found'; end if;

  if public.role_canonical_department(v_actor_role) is distinct from v_job.canonical_department
     and upper(coalesce(v_actor_role,'')) not in ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') then
    raise exception 'Actor is not authorised for department %', v_job.canonical_department using errcode = '42501';
  end if;

  if v_job.status <> 'completed' or not v_job.locked then
    raise exception 'Job must be declared ready before dispatch to RGS';
  end if;
  if p_dispatched_qty is null or p_dispatched_qty <= 0 or p_dispatched_qty > v_job.produced_qty then
    raise exception 'Dispatched quantity must be positive and cannot exceed declared output';
  end if;

  select sku into v_product_sku from public.products where id = v_job.product_id;

  insert into public.production_rgs_transfers (
    job_id, product_id, sku, quantity, declared_qty, batch_number, transferred_by,
    status, destination_store_code, correlation_id
  ) values (
    p_job_id, v_job.product_id, v_product_sku, p_dispatched_qty, v_job.produced_qty, v_job.batch_number, v_actor_id,
    'in_transit', p_destination_store_code, p_correlation_id
  )
  returning * into v_transfer;

  update public.production_jobs set status = 'transferred', updated_at = now() where id = p_job_id;
  return v_transfer;
end;
$$;

create or replace function public.report_production_issue(
  p_job_id uuid,
  p_department text,
  p_issue_type text,
  p_comment text,
  p_photo_url text default null,
  p_correlation_id text default null
)
returns public.production_issues
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_existing public.production_issues%rowtype;
  v_issue public.production_issues%rowtype;
  v_severity text;
  v_correlation_id text := nullif(btrim(coalesce(p_correlation_id, '')), '');
  v_job_department text;
  v_job_canonical_department text;
  v_canonical_dept text;
begin
  select role into v_actor_role from public.users where id = v_actor_id;
  if v_actor_id is null or public.is_internal_staff(v_actor_id) is not true then
    raise exception 'Not authorised to report a production issue' using errcode = '42501';
  end if;
  if p_job_id is null then raise exception 'A job_id is required'; end if;
  if nullif(btrim(coalesce(p_department, '')), '') is null then raise exception 'A department is required'; end if;
  if p_issue_type is null or p_issue_type not in ('material', 'machine', 'delay') then
    raise exception 'issue_type must be one of material, machine, delay';
  end if;
  if nullif(btrim(coalesce(p_comment, '')), '') is null then
    raise exception 'A comment describing the issue is required';
  end if;
  if v_correlation_id is null then raise exception 'A correlation id is required'; end if;

  select department, canonical_department
    into v_job_department, v_job_canonical_department
  from public.production_jobs
  where id = p_job_id;
  if not found then raise exception 'Production job % not found', p_job_id; end if;

  if public.role_canonical_department(v_actor_role) is distinct from v_job_canonical_department
     and upper(coalesce(v_actor_role,'')) not in ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') then
    raise exception 'Actor is not authorised for department %', v_job_canonical_department using errcode = '42501';
  end if;

  v_canonical_dept := public.canonical_production_department(p_department);
  if v_canonical_dept is null or v_canonical_dept is distinct from v_job_canonical_department then
    raise exception 'department % does not match production job %''s department', p_department, p_job_id;
  end if;

  select * into v_existing from public.production_issues where correlation_id = v_correlation_id;
  if found then return v_existing; end if;

  v_severity := case p_issue_type when 'machine' then 'urgent' when 'delay' then 'warning' else 'warning' end;

  begin
    insert into public.production_issues (
      job_id, department, issue_type, comment, photo_url, reported_by, correlation_id
    ) values (
      p_job_id, v_job_department, p_issue_type, btrim(p_comment), p_photo_url, v_actor_id, v_correlation_id
    )
    returning * into v_issue;
  exception when unique_violation then
    select * into v_existing from public.production_issues where correlation_id = v_correlation_id;
    if found then return v_existing; end if;
    raise;
  end;

  perform public.append_operational_event_v1(
    p_event_type := 'production_issue_escalation',
    p_entity_type := 'production_issue',
    p_entity_id := v_issue.id,
    p_title := 'Production issue: ' || p_issue_type || ' (' || v_job_department || ')',
    p_source_application := 'production',
    p_correlation_id := v_correlation_id,
    p_actor_id := v_actor_id,
    p_actor_department := v_job_department,
    p_severity := v_severity,
    p_message := btrim(p_comment),
    p_idempotency_key := 'production-issue-escalation:' || v_correlation_id
  );

  return v_issue;
end;
$$;

create or replace function public.resolve_production_issue(
  p_issue_id uuid,
  p_resolution_notes text
)
returns public.production_issues
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_issue public.production_issues%rowtype;
  v_job_canonical_department text;
begin
  select role into v_actor_role from public.users where id = v_actor_id;
  if v_actor_id is null or public.is_internal_staff(v_actor_id) is not true then
    raise exception 'Not authorised to resolve a production issue' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_resolution_notes, '')), '') is null then
    raise exception 'Resolution notes are required';
  end if;

  select * into v_issue from public.production_issues where id = p_issue_id for update;
  if not found then raise exception 'Production issue % not found', p_issue_id; end if;

  select canonical_department into v_job_canonical_department
  from public.production_jobs
  where id = v_issue.job_id;
  if not found then raise exception 'Production job % not found', v_issue.job_id; end if;

  if public.role_canonical_department(v_actor_role) is distinct from v_job_canonical_department
     and upper(coalesce(v_actor_role,'')) not in ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') then
    raise exception 'Actor is not authorised for department %', v_job_canonical_department using errcode = '42501';
  end if;

  if v_issue.status = 'resolved' then return v_issue; end if;

  update public.production_issues
  set status = 'resolved', resolved_by = v_actor_id, resolved_at = now(), resolution_notes = btrim(p_resolution_notes)
  where id = p_issue_id
  returning * into v_issue;

  perform public.append_operational_event_v1(
    p_event_type := 'production_issue_resolved',
    p_entity_type := 'production_issue',
    p_entity_id := v_issue.id,
    p_title := 'Production issue resolved: ' || v_issue.issue_type || ' (' || v_issue.department || ')',
    p_source_application := 'production',
    p_correlation_id := 'resolve-' || p_issue_id::text,
    p_actor_id := v_actor_id,
    p_actor_department := v_issue.department,
    p_severity := 'info',
    p_message := btrim(p_resolution_notes),
    p_idempotency_key := 'resolve-' || p_issue_id::text
  );

  return v_issue;
end;
$$;

comment on function public.dispatch_production_to_rgs(uuid,numeric,text,text) is
  'Department-scoped Production -> RGS transfer. Department HOD/operator or governed production/operations/admin override only.';
comment on function public.report_production_issue(uuid,text,text,text,text,text) is
  'Department-scoped production issue reporting with canonical job-department binding.';
comment on function public.resolve_production_issue(uuid,text) is
  'Department-scoped production issue resolution; cross-department staff are rejected server-side.';

commit;
