-- MC#629 — minimal party search for the ORIGINAL_COMMUNICATOR confirmation
-- control. Central's OperatorInboxCommercialLayers.tsx currently requires an
-- operator to hand-type a canonical party UUID with no lookup; this mirrors
-- the existing whatsapp_search_b2b_companies() pattern (same permission gate,
-- same shape) across the existing company/contact/employee tables so the
-- operator can search and select instead of typing a UUID blind. No new
-- identity table, no new master; reads only existing governed tables.
begin;

create or replace function public.whatsapp_search_case_parties(
  p_party_type text,
  p_query text,
  p_limit integer default 20
)
returns table(
  id uuid,
  party_type text,
  display_label text,
  phone text,
  company_id uuid,
  company_name text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_type text := upper(btrim(coalesce(p_party_type, '')));
  v_query text := btrim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 30));
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;
  if v_type not in ('COMPANY', 'CUSTOMER', 'CONTACT', 'EMPLOYEE') then
    raise exception 'party search requires COMPANY, CUSTOMER, CONTACT or EMPLOYEE';
  end if;
  if length(v_query) < 2 or length(v_query) > 100 then
    raise exception 'party search requires 2-100 characters';
  end if;

  if v_type in ('COMPANY', 'CUSTOMER') then
    return query
    select c.id, 'COMPANY'::text, c.business_name, c.phone, c.id, c.business_name
    from public.companies c
    where c.business_name ilike '%' || v_query || '%'
       or coalesce(c.phone, '') ilike '%' || v_query || '%'
       or coalesce(c.gst_number, '') ilike '%' || v_query || '%'
    order by
      case when lower(c.business_name) = lower(v_query) then 0
           when lower(c.business_name) like lower(v_query) || '%' then 1
           else 2 end,
      c.business_name, c.id
    limit v_limit;
  elsif v_type = 'CONTACT' then
    return query
    select oc.id, 'CONTACT'::text, oc.name, oc.phone, oc.company_id, c.business_name
    from public.org_contacts oc
    left join public.companies c on c.id = oc.company_id
    where oc.name ilike '%' || v_query || '%'
       or coalesce(oc.phone, '') ilike '%' || v_query || '%'
    order by
      case when lower(oc.name) = lower(v_query) then 0
           when lower(oc.name) like lower(v_query) || '%' then 1
           else 2 end,
      oc.name, oc.id
    limit v_limit;
  else
    return query
    select u.id, 'EMPLOYEE'::text,
      coalesce(nullif(u.full_name, ''), nullif(u.name, '')),
      coalesce(nullif(u.mobile_number, ''), u.phone),
      null::uuid, null::text
    from public.users u
    where u.deleted_at is null
      and coalesce(u.is_active, true)
      and (
        coalesce(u.full_name, '') ilike '%' || v_query || '%'
        or coalesce(u.name, '') ilike '%' || v_query || '%'
        or coalesce(u.mobile_number, '') ilike '%' || v_query || '%'
        or coalesce(u.phone, '') ilike '%' || v_query || '%'
      )
    order by
      case when lower(coalesce(u.full_name, u.name, '')) = lower(v_query) then 0
           when lower(coalesce(u.full_name, u.name, '')) like lower(v_query) || '%' then 1
           else 2 end,
      coalesce(u.full_name, u.name), u.id
    limit v_limit;
  end if;
end;
$$;

comment on function public.whatsapp_search_case_parties(text, text, integer) is
  'Minimal company/contact/employee lookup for authorised WhatsApp inbox readers, used by the ORIGINAL_COMMUNICATOR confirmation picker. Returns identity candidates only; selection and confirmation remain a separate human authority action via whatsapp_confirm_original_communicator.';
revoke all on function public.whatsapp_search_case_parties(text, text, integer) from public, anon;
grant execute on function public.whatsapp_search_case_parties(text, text, integer) to authenticated;

commit;
