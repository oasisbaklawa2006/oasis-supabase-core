-- Final certification repair: allow a rejected B2B applicant to start a new,
-- independent review cycle without mutating the historical rejection.
-- Contract test: 20261001233000_b2b_reapply_after_rejection.sql
set local lock_timeout = '5s';
set local statement_timeout = '60s';

begin;

drop index if exists public.uq_b2b_applications_email_mobile;
create unique index uq_b2b_applications_email_mobile
  on public.b2b_applications (lower(contact_email), mobile_number)
  where contact_email is not null
    and mobile_number is not null
    and coalesce(status,'') <> 'rejected';

create or replace function public.submit_b2b_access_request_v2(
  p_business_name text,
  p_contact_name text,
  p_contact_email text,
  p_contact_phone text,
  p_gst_number text default null,
  p_registered_address text default null,
  p_preferred_dispatch text default null,
  p_preferred_dispatch_other_name text default null,
  p_trade_declaration boolean default false,
  p_data_consent boolean default false
)
returns table (
  application_id uuid,
  application_status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_email text := lower(btrim(coalesce(p_contact_email, '')));
  v_mobile text := public.normalize_b2b_access_mobile_v2(coalesce(p_contact_phone, ''));
  v_existing public.b2b_applications%rowtype;
  v_rejected public.b2b_applications%rowtype;
  v_app_id uuid;
begin
  if coalesce(btrim(p_business_name), '') = '' then
    raise exception 'VALIDATION_FAILED: business_name is required' using errcode = '22023';
  end if;
  if coalesce(btrim(p_contact_name), '') = '' then
    raise exception 'VALIDATION_FAILED: contact_name is required' using errcode = '22023';
  end if;
  if v_email = '' or position('@' in v_email) <= 1 then
    raise exception 'VALIDATION_FAILED: valid contact_email is required' using errcode = '22023';
  end if;
  if v_mobile is null or length(v_mobile) < 10 or length(v_mobile) > 15 then
    raise exception 'VALIDATION_FAILED: valid contact_phone is required' using errcode = '22023';
  end if;
  if not coalesce(p_trade_declaration, false) or not coalesce(p_data_consent, false) then
    raise exception 'VALIDATION_FAILED: trade_declaration and data_consent must both be accepted'
      using errcode = '22023';
  end if;

  -- Active/non-rejected identity wins. Pending and approved applications remain
  -- idempotent duplicates and never create a parallel active review cycle.
  select *
    into v_existing
  from public.b2b_applications a
  where lower(btrim(coalesce(a.contact_email, ''))) = v_email
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
    and coalesce(a.status,'') <> 'rejected'
  order by a.created_at desc nulls last
  limit 1;

  if found then
    return query select v_existing.id, v_existing.status, true;
    return;
  end if;

  -- Keep the most recent rejection only as audit lineage. It is never reopened
  -- or rewritten; the new submission becomes a fresh pending application.
  select *
    into v_rejected
  from public.b2b_applications a
  where lower(btrim(coalesce(a.contact_email, ''))) = v_email
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
    and a.status = 'rejected'
  order by a.created_at desc nulls last
  limit 1;

  begin
    insert into public.b2b_applications (
      business_name,
      contact_name,
      contact_person,
      contact_email,
      contact_phone,
      mobile_number,
      gst_number,
      registered_address,
      preferred_dispatch,
      preferred_dispatch_other_name,
      trade_declaration,
      data_consent,
      user_id,
      resolved_company_id,
      status
    ) values (
      btrim(p_business_name),
      btrim(p_contact_name),
      btrim(p_contact_name),
      v_email,
      btrim(p_contact_phone),
      v_mobile,
      nullif(btrim(p_gst_number), ''),
      nullif(btrim(p_registered_address), ''),
      nullif(btrim(p_preferred_dispatch), ''),
      case
        when upper(coalesce(btrim(p_preferred_dispatch), '')) = 'OTHER'
          then nullif(btrim(p_preferred_dispatch_other_name), '')
        else null
      end,
      true,
      true,
      null,
      null,
      'pending'
    )
    returning id into v_app_id;
  exception when unique_violation then
    -- Concurrent retry/reapply: the partial unique index allows only one
    -- non-rejected row for this canonical identity.
    select *
      into v_existing
    from public.b2b_applications a
    where lower(btrim(coalesce(a.contact_email, ''))) = v_email
      and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
      and coalesce(a.status,'') <> 'rejected'
    order by a.created_at desc nulls last
    limit 1;

    if found then
      return query select v_existing.id, v_existing.status, true;
      return;
    end if;
    raise;
  end;

  if v_rejected.id is not null then
    insert into public.audit_logs (
      action_type, module_name, entity_name, entity_id, actor_id,
      reason, new_value, risk_level
    ) values (
      'B2B_ACCESS_REQUEST_REAPPLIED',
      'b2b_onboarding',
      'b2b_applications',
      v_app_id::text,
      auth.uid(),
      'Fresh application created after prior rejection; historical rejection preserved.',
      jsonb_build_object(
        'previous_application_id', v_rejected.id,
        'previous_reviewed_at', v_rejected.reviewed_at
      ),
      'normal'
    );
  end if;

  return query select v_app_id, 'pending'::text, false;
end;
$$;

revoke all on function public.submit_b2b_access_request_v2(
  text,text,text,text,text,text,text,text,boolean,boolean
) from public;
grant execute on function public.submit_b2b_access_request_v2(
  text,text,text,text,text,text,text,text,boolean,boolean
) to anon, authenticated, service_role;

commit;
