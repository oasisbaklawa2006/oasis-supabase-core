-- WA-100 / #540 — atomic at-most-once claim for legacy order WhatsApp events.
-- Retains existing order/contact foreign keys and never calls a provider.
-- No existing production automation rows as of read-only inspection 16 Nov 2026.
-- Fail closed for any duplicate order+event key, including failed/unknown sends.
begin;

create unique index if not exists wa100_legacy_automation_order_trigger_once
  on public.whatsapp_automations (order_id, trigger_type);

create or replace function public.claim_legacy_whatsapp_automation_v1(
  p_order_id uuid,
  p_trigger_type text,
  p_phone_digits text,
  p_template text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_contact_id uuid;
  v_id uuid;
  v_status text;
  v_claimed boolean := false;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'WA100_AUTOMATION_SERVICE_ONLY' using errcode = '42501';
  end if;
  if p_order_id is null then
    raise exception 'WA100_AUTOMATION_ORDER_REQUIRED' using errcode = '22023';
  end if;
  if p_trigger_type is null or p_trigger_type not in (
    'so_created','payment_verified','production_started','order_dispatched'
  ) then
    raise exception 'WA100_AUTOMATION_TRIGGER_INVALID' using errcode = '22023';
  end if;
  if p_phone_digits is null or p_phone_digits !~ '^[1-9][0-9]{9,14}$' then
    raise exception 'WA100_AUTOMATION_PHONE_INVALID' using errcode = '22023';
  end if;
  if p_template is null or p_template !~ '^[a-z][a-z0-9_]{1,63}$' then
    raise exception 'WA100_AUTOMATION_TEMPLATE_INVALID' using errcode = '22023';
  end if;
  -- A missing order cannot trigger an external notification. Lock order record
  -- for the duration of the claim transaction to stabilize order authority.
  perform 1 from public.orders where id=p_order_id for key share;
  if not found then
    raise exception 'WA100_AUTOMATION_ORDER_NOT_FOUND' using errcode = '23503';
  end if;

  insert into public.whatsapp_contacts(phone_number, wa_contact_id)
  values (p_phone_digits, p_phone_digits)
  on conflict (phone_number) do nothing;
  select id into v_contact_id
  from public.whatsapp_contacts
  where phone_number = p_phone_digits;
  if v_contact_id is null then
    raise exception 'WA100_AUTOMATION_CONTACT_UNAVAILABLE';
  end if;

  insert into public.whatsapp_automations(
    contact_id, order_id, trigger_type, message_template,
    provider, status, retry_count
  ) values (
    v_contact_id, p_order_id, p_trigger_type, p_template,
    'click2api', 'pending', 0
  )
  on conflict (order_id, trigger_type) do nothing
  returning id into v_id;
  v_claimed := v_id is not null;

  if not v_claimed then
    select id, status into v_id, v_status
    from public.whatsapp_automations
    where order_id=p_order_id and trigger_type=p_trigger_type;
  else
    v_status := 'pending';
  end if;
  if v_id is null then
    raise exception 'WA100_AUTOMATION_CLAIM_UNAVAILABLE';
  end if;

  return jsonb_build_object(
    'claimed',v_claimed,
    'automation_id',v_id,
    'status',v_status
  );
end;
$$;
revoke all on function public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.claim_legacy_whatsapp_automation_v1(uuid,text,text,text)
  to service_role;

commit;
