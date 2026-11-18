-- WA-100 forward correction of the preview-applied queue migration.
-- Do not repurpose editable admin_notes as a durable retry identity.
-- This column is an internal origin marker, not proof of phone verification or consent.
alter table public.b2b_applications
  add column if not exists wa100_shadow_queue_origin text;

comment on column public.b2b_applications.wa100_shadow_queue_origin is
  'Internal WA-100 shadow approval queue origin; no WhatsApp contact consent implied.';

-- Preserve identity for applications created on earlier isolated previews before
-- this column existed. Do not claim unrelated pending buyer applications.
update public.b2b_applications a
set wa100_shadow_queue_origin = 'wa100_shadow_queue_v1',
    mobile_number = coalesce(nullif(btrim(a.mobile_number), ''), a.contact_phone)
from public.companies c
where c.id = a.resolved_company_id
  and c.status = 'pending_approval'
  and a.status = 'pending'
  and a.user_id is null
  and a.admin_notes = 'War Room WhatsApp triage — pending governance approval'
  and a.wa100_shadow_queue_origin is null;

create or replace function public.queue_whatsapp_shadow_client_for_approval_v1(
  p_company_id uuid,
  p_business_name text,
  p_gst_number text,
  p_fssai_number text,
  p_registered_address text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_company public.companies%rowtype;
  v_application_id uuid;
  v_business_name text := nullif(btrim(p_business_name), '');
  v_gst_number text := nullif(btrim(p_gst_number), '');
  v_fssai_number text := nullif(btrim(p_fssai_number), '');
  v_registered_address text := nullif(btrim(p_registered_address), '');
  v_phone text;
  v_source constant text := 'War Room WhatsApp triage — pending governance approval';
begin
  perform 1
  from public.users
  where id = v_actor_id and is_active is true
  for share;

  if not found or coalesce(public.get_user_role(v_actor_id), '') not in ('ADMIN', 'SUPER_ADMIN') then
    raise exception 'Shadow client approval requires an active administrator' using errcode = '42501';
  end if;

  if v_business_name is null then
    raise exception 'Business name is required' using errcode = '22023';
  end if;

  select * into v_company
  from public.companies
  where id = p_company_id
  for update;

  if v_company.status = 'pending_approval' then
    select a.id into v_application_id
    from public.b2b_applications a
    where a.resolved_company_id = p_company_id
      and a.status = 'pending'
      and a.wa100_shadow_queue_origin = 'wa100_shadow_queue_v1'
    order by a.id
    limit 1;
    if found then
      if v_company.business_name is distinct from v_business_name
         or v_company.gst_number is distinct from v_gst_number
         or v_company.fssai_number is distinct from v_fssai_number
         or v_company.registered_address is distinct from v_registered_address then
        raise exception 'Client is already queued with different details' using errcode = '55000';
      end if;
      return v_application_id;
    end if;
  end if;

  if v_company.status is distinct from 'shadow' then
    raise exception 'Company is no longer in the Shadow Client queue' using errcode = '55000';
  end if;

  if exists (
    select 1 from public.b2b_applications a
    where a.resolved_company_id = p_company_id
      and a.status not in ('rejected', 'cancelled')
  ) then
    raise exception 'This company already has an application in Client Governance' using errcode = '55000';
  end if;

  v_phone := coalesce(
    nullif(btrim(v_company.phone), ''),
    case when v_company.gst_number ~ '^WA:[0-9]{10,15}$'
         then '+' || substr(v_company.gst_number, 4) end
  );

  update public.companies
  set business_name = v_business_name,
      gst_number = v_gst_number,
      fssai_number = v_fssai_number,
      registered_address = v_registered_address,
      phone = v_phone,
      status = 'pending_approval'
  where id = p_company_id;

  insert into public.b2b_applications (
    resolved_company_id, business_name, gst_number, registered_address,
    contact_phone, mobile_number, status, admin_notes, wa100_shadow_queue_origin
  )
  values (
    p_company_id, v_business_name, v_gst_number,
    v_registered_address, v_phone, v_phone, 'pending', v_source, 'wa100_shadow_queue_v1'
  )
  returning id into v_application_id;

  return v_application_id;
end;
$$;

revoke all on function public.queue_whatsapp_shadow_client_for_approval_v1(uuid, text, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.queue_whatsapp_shadow_client_for_approval_v1(uuid, text, text, text, text)
  to authenticated;
