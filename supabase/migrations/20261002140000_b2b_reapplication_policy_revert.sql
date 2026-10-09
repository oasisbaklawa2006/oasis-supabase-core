-- Targeted rectification: restore the pre-#384 B2B application contract.
-- #384 was merged to Git but never applied to production. Migration history is
-- immutable, so this forward correction preserves history while restoring the
-- production-approved behavior on clean replay and future releases.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Fail closed before restoring the pre-#384 uniqueness contract. An environment
-- that actually ran #384 may contain a rejected row plus a later active row for
-- the same canonical email/mobile pair. Automatically deleting or rewriting either
-- row would destroy application history, so those environments require explicit
-- governed reconciliation before this corrective migration can proceed.
do $rectify$
declare
  v_conflict_groups bigint;
begin
  select count(*)
    into v_conflict_groups
  from (
    select lower(contact_email) as canonical_email, mobile_number
    from public.b2b_applications
    where contact_email is not null
      and mobile_number is not null
    group by lower(contact_email), mobile_number
    having count(*) > 1
  ) conflicts;

  if v_conflict_groups > 0 then
    raise exception
      'B2B_REAPPLICATION_POLICY_REVERT_CONFLICT: % duplicate email/mobile identity group(s) require governed reconciliation before restoring pre-#384 uniqueness; rejected application history is preserved and no rows were changed',
      v_conflict_groups
      using errcode = '23505';
  end if;
end;
$rectify$;

drop index if exists public.uq_b2b_applications_email_mobile;
create unique index uq_b2b_applications_email_mobile
  on public.b2b_applications (lower(contact_email), mobile_number)
  where contact_email is not null
    and mobile_number is not null;

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

  select *
    into v_existing
  from public.b2b_applications a
  where lower(btrim(coalesce(a.contact_email, ''))) = v_email
    and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
  order by a.created_at desc nulls last
  limit 1;

  if found then
    return query select v_existing.id, v_existing.status, true;
    return;
  end if;

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
    select *
      into v_existing
    from public.b2b_applications a
    where lower(btrim(coalesce(a.contact_email, ''))) = v_email
      and public.normalize_b2b_access_mobile_v2(coalesce(a.mobile_number, a.contact_phone, '')) = v_mobile
    order by a.created_at desc nulls last
    limit 1;

    if found then
      return query select v_existing.id, v_existing.status, true;
      return;
    end if;
    raise;
  end;

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
