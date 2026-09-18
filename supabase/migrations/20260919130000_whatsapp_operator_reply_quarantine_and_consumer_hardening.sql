-- Gate 5b: quarantine historical Gate-3 stale autonomous receipts and harden
-- governed operator-reply outbox claim/lease authority for the durable consumer.
-- Contract coverage: supabase/tests/20260919130000_whatsapp_operator_reply_consumer_hardening.sql
begin;

alter table public.whatsapp_operator_reply_outbox
  drop constraint if exists whatsapp_operator_reply_outbox_status_check;

alter table public.whatsapp_operator_reply_outbox
  add constraint whatsapp_operator_reply_outbox_status_check
  check (
    status in (
      'QUEUED', 'SENDING', 'ACCEPTANCE_UNKNOWN', 'ACCEPTED', 'DELIVERED', 'READ',
      'FAILED_RETRYABLE', 'FAILED_FINAL', 'CANCELLED', 'QUARANTINED'
    )
  );

alter table public.whatsapp_operator_reply_outbox
  add column if not exists message_origin text not null default 'STAFF'
    check (message_origin in ('STAFF', 'AUTONOMOUS'));

alter table public.whatsapp_operator_reply_outbox
  add column if not exists quarantine_reason text,
  add column if not exists quarantined_at timestamptz,
  add column if not exists quarantine_evidence jsonb;

-- destructive-change-approved: replace legacy auto-named provider acceptance checks with one explicit constraint
-- rollback-plan: drop whatsapp_operator_reply_outbox_provider_message_id_check and restore wa5 check2 definition
alter table public.whatsapp_operator_reply_outbox
  drop constraint if exists whatsapp_operator_reply_outbox_check2;

alter table public.whatsapp_operator_reply_outbox
  drop constraint if exists whatsapp_operator_reply_outbox_provider_message_id_check;

alter table public.whatsapp_operator_reply_outbox
  add constraint whatsapp_operator_reply_outbox_provider_message_id_check
  check (
    provider_message_id is null
    or status in ('ACCEPTED', 'DELIVERED', 'READ')
  );

update public.whatsapp_operator_reply_outbox
set message_origin = 'AUTONOMOUS'
where message_origin = 'STAFF'
  and (
    idempotency_key like 'core-c:%'
    or created_by = public.whatsapp_core_c_system_actor_id()
  );

create or replace function public.enqueue_whatsapp_operator_reply(
  p_packet_id uuid,
  p_contact_id uuid,
  p_recipient_phone text,
  p_message_body text,
  p_idempotency_key text,
  p_potential_order_id uuid default null,
  p_clarification_task_id uuid default null,
  p_message_type text default 'TEXT',
  p_template_name text default null,
  p_template_language text default null,
  p_media_reference text default null,
  p_disclosure_scope text[] default '{}'
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_contact public.whatsapp_contacts%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_phone text;
  v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
  if auth.uid() is null or not public.has_whatsapp_permission('wa.reply.send') then
    raise exception 'WA5_REPLY_SEND_REQUIRED' using errcode = 'P0001';
  end if;
  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  select * into v_contact from public.whatsapp_contacts where id = p_contact_id;
  if v_packet.id is null or v_contact.id is null or v_packet.contact_id <> v_contact.id then
    raise exception 'WA5_PACKET_CONTACT_MISMATCH';
  end if;
  v_phone := '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g');
  if v_phone <> ('+' || regexp_replace(p_recipient_phone, '\D', '', 'g')) then
    raise exception 'WA5_RECIPIENT_MISMATCH';
  end if;
  if p_potential_order_id is not null and not exists (
    select 1 from public.whatsapp_potential_orders po
    where po.id = p_potential_order_id
      and po.sender_key = regexp_replace(v_phone, '\D', '', 'g')
  ) then
    raise exception 'WA5_POTENTIAL_ORDER_BOUNDARY_MISMATCH';
  end if;
  if p_clarification_task_id is not null and not exists (
    select 1 from public.whatsapp_order_clarification_tasks t
    where t.id = p_clarification_task_id
      and t.potential_order_id = p_potential_order_id
      and t.status = 'OPEN'
  ) then
    raise exception 'WA5_CLARIFICATION_BOUNDARY_MISMATCH';
  end if;
  insert into public.whatsapp_operator_reply_outbox(
    packet_id, contact_id, potential_order_id, clarification_task_id,
    recipient_phone_e164, message_body, message_type, template_name,
    template_language, media_reference, disclosure_scope, idempotency_key,
    created_by, message_origin
  ) values (
    p_packet_id, p_contact_id, p_potential_order_id, p_clarification_task_id,
    v_phone, btrim(p_message_body), upper(p_message_type),
    nullif(btrim(p_template_name), ''), nullif(btrim(p_template_language), ''),
    nullif(btrim(p_media_reference), ''), coalesce(p_disclosure_scope, '{}'),
    btrim(p_idempotency_key), auth.uid(), 'STAFF'
  )
  on conflict (packet_id, idempotency_key) do update
  set idempotency_key = excluded.idempotency_key
  returning * into v_result;
  insert into public.whatsapp_operator_reply_events(reply_id, event_type, actor_id, evidence)
  values (
    v_result.id, 'ENQUEUED_OR_REPLAYED', auth.uid(),
    jsonb_build_object(
      'permission', 'wa.reply.send',
      'recipient', v_phone,
      'message_origin', 'STAFF',
      'clarification_task_id', p_clarification_task_id
    )
  );
  return v_result;
end;
$$;

create or replace function public.enqueue_governed_whatsapp_autonomous_reply(
  p_packet_id uuid,
  p_contact_id uuid,
  p_recipient_phone text,
  p_message_body text,
  p_idempotency_key text,
  p_purpose text,
  p_potential_order_id uuid default null,
  p_case_id uuid default null,
  p_clarification_id uuid default null,
  p_disclosure_scope text[] default '{}'::text[]
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_principal uuid;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_phone text;
  v_body text := btrim(coalesce(p_message_body, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_purpose text := upper(btrim(coalesce(p_purpose, '')));
  v_scope text[];
  v_result public.whatsapp_operator_reply_outbox%rowtype;
  v_inferred text[];
  v_recipient jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if length(v_body) < 8 or length(v_body) > 4000 then
    raise exception 'CORE_C_OUTBOUND_BODY_INVALID';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'CORE_C_IDEMPOTENCY_KEY_REQUIRED';
  end if;
  if v_purpose not in (
    'PROMOTED_ORDER_ACK', 'AUTONOMY_CLARIFICATION', 'NON_ORDER_RECEIPT', 'CASE_RECEIPT'
  ) then
    raise exception 'CORE_C_UNSUPPORTED_OUTBOUND_PURPOSE';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();
  v_recipient := public.whatsapp_core_c_classify_outbound_recipient_v1(
    p_contact_id, p_potential_order_id
  );

  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  select * into v_contact from public.whatsapp_contacts where id = p_contact_id;
  if v_packet.id is null or v_contact.id is null or v_packet.contact_id <> v_contact.id then
    raise exception 'CORE_C_PACKET_CONTACT_MISMATCH';
  end if;

  v_phone := '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g');
  if v_phone <> ('+' || regexp_replace(p_recipient_phone, '\D', '', 'g')) then
    raise exception 'CORE_C_RECIPIENT_MISMATCH';
  end if;

  v_inferred := coalesce(public.wa6_infer_commercial_disclosure(v_body), '{}'::text[]);

  if v_purpose in ('AUTONOMY_CLARIFICATION', 'NON_ORDER_RECEIPT', 'CASE_RECEIPT') then
    if cardinality(v_inferred) > 0 then
      raise exception 'CORE_C_UNSAFE_OUTBOUND_DISCLOSURE';
    end if;
    v_scope := '{}'::text[];
  elsif v_purpose = 'PROMOTED_ORDER_ACK' then
    if v_inferred && array[
      'customer_pricing', 'account_balance', 'payment_terms', 'moq_carton',
      'delivery_address', 'previous_orders', 'draft_order'
    ]::text[] then
      raise exception 'CORE_C_UNSAFE_OUTBOUND_DISCLOSURE';
    end if;
    select coalesce(array_agg(distinct scope order by scope), '{}'::text[])
    into v_scope
    from unnest(coalesce(p_disclosure_scope, '{}'::text[]) || v_inferred) scope
    where btrim(scope) <> '';
    if 'sales_order' = any(v_scope)
       and upper(v_recipient->>'recipient_class') <> 'VERIFIED_COMMERCIAL_CUSTOMER' then
      raise exception 'CORE_C_PROMOTED_ACK_COMMERCIAL_AUTH_REQUIRED';
    end if;
  else
    v_scope := '{}'::text[];
  end if;

  insert into public.whatsapp_operator_reply_outbox(
    packet_id, contact_id, potential_order_id, clarification_task_id,
    recipient_phone_e164, message_body, message_type, disclosure_scope,
    idempotency_key, created_by, message_origin
  ) values (
    p_packet_id, p_contact_id, p_potential_order_id, null,
    v_phone, v_body, 'TEXT', v_scope, v_key, v_principal, 'AUTONOMOUS'
  )
  on conflict (packet_id, idempotency_key) do update
  set idempotency_key = excluded.idempotency_key
  returning * into v_result;

  insert into public.whatsapp_operator_reply_events(reply_id, event_type, actor_id, evidence)
  values (
    v_result.id,
    'CORE_C_ENQUEUED_OR_REPLAYED',
    null,
    jsonb_build_object(
      'purpose', v_purpose,
      'actor_type', 'SYSTEM',
      'system_principal_id', v_principal,
      'message_origin', 'AUTONOMOUS',
      'recipient_class', v_recipient->>'recipient_class',
      'case_id', p_case_id,
      'clarification_id', p_clarification_id,
      'idempotency_key', v_key
    )
  );

  if p_case_id is not null then
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_type, correlation_key, resulting_state, metadata
    ) values (
      p_case_id, 'AUTONOMOUS_OUTBOUND_ENQUEUED', 'SYSTEM',
      'core-c-outbound:' || v_key,
      jsonb_build_object(
        'purpose', v_purpose,
        'reply_id', v_result.id,
        'status', v_result.status,
        'recipient_class', v_recipient->>'recipient_class'
      ),
      jsonb_build_object(
        'message_body', v_body,
        'clarification_id', p_clarification_id,
        'system_principal_id', v_principal
      )
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  return v_result;
end;
$$;

create or replace function public.quarantine_whatsapp_operator_reply(
  p_reply_id uuid,
  p_reason text,
  p_evidence jsonb default '{}'::jsonb
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result public.whatsapp_operator_reply_outbox%rowtype;
  v_prior_status text;
  v_reason text := left(btrim(coalesce(p_reason, '')), 240);
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;
  if p_reply_id is null or v_reason = '' then
    raise exception 'WA5_QUARANTINE_INPUT_REQUIRED' using errcode = '22023';
  end if;

  select status into v_prior_status
  from public.whatsapp_operator_reply_outbox
  where id = p_reply_id;

  update public.whatsapp_operator_reply_outbox
  set
    status = 'QUARANTINED',
    quarantine_reason = v_reason,
    quarantined_at = statement_timestamp(),
    quarantine_evidence = coalesce(p_evidence, '{}'::jsonb),
    lease_token = null,
    lease_expires_at = null,
    next_attempt_at = 'infinity'::timestamptz,
    updated_at = statement_timestamp()
  where id = p_reply_id
    and status in (
      'QUEUED', 'SENDING', 'FAILED_RETRYABLE', 'ACCEPTANCE_UNKNOWN'
    )
  returning * into v_result;

  if not found then
    raise exception 'WA5_QUARANTINE_BOUNDARY';
  end if;

  insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
  values (
    v_result.id,
    'QUARANTINED',
    coalesce(p_evidence, '{}'::jsonb) || jsonb_build_object(
      'reason', v_reason,
      'prior_status', v_prior_status,
      'message_origin', v_result.message_origin,
      'idempotency_key', v_result.idempotency_key
    )
  );

  return v_result;
end;
$$;

create or replace function public.disposition_historical_gate3_stale_autonomous_receipts()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_row public.whatsapp_operator_reply_outbox%rowtype;
  v_count integer := 0;
  v_ids uuid[] := '{}'::uuid[];
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;

  for v_row in
    select *
    from public.whatsapp_operator_reply_outbox
    where status in ('QUEUED', 'SENDING', 'FAILED_RETRYABLE')
      and provider_message_id is null
      and idempotency_key like 'core-c:non-order-receipt:%'
      and message_origin = 'AUTONOMOUS'
    order by created_at
    for update
  loop
    perform public.quarantine_whatsapp_operator_reply(
      v_row.id,
      'HISTORICAL_GATE3_STALE_AUTONOMOUS_RECEIPT',
      jsonb_build_object(
        'disposition', 'DO_NOT_SEND',
        'gate', 'Gate-3-backlog-drain',
        'idempotency_key', v_row.idempotency_key,
        'packet_id', v_row.packet_id,
        'created_at', v_row.created_at
      )
    );
    v_count := v_count + 1;
    v_ids := array_append(v_ids, v_row.id);
  end loop;

  return jsonb_build_object(
    'disposition', 'HISTORICAL_GATE3_STALE_AUTONOMOUS_RECEIPT',
    'quarantined_count', v_count,
    'reply_ids', v_ids
  );
end;
$$;

create or replace function public.claim_whatsapp_operator_reply(
  p_worker_id text,
  p_reply_id uuid default null,
  p_lease_seconds integer default 60
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result public.whatsapp_operator_reply_outbox%rowtype;
  v_worker text := left(btrim(coalesce(p_worker_id, '')), 120);
  v_lease integer := greatest(15, least(coalesce(p_lease_seconds, 60), 300));
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;
  if v_worker = '' then
    raise exception 'WA5_WORKER_ID_REQUIRED' using errcode = '22023';
  end if;

  with candidate as (
    select id
    from public.whatsapp_operator_reply_outbox
    where (
      (
        status in ('QUEUED', 'FAILED_RETRYABLE')
        and next_attempt_at <= statement_timestamp()
      ) or (
        status = 'SENDING'
        and lease_expires_at <= statement_timestamp()
      )
    )
      and status not in (
        'QUARANTINED', 'CANCELLED', 'ACCEPTANCE_UNKNOWN',
        'ACCEPTED', 'DELIVERED', 'READ', 'FAILED_FINAL'
      )
      and (p_reply_id is null or id = p_reply_id)
    order by created_at
    for update skip locked
    limit 1
  )
  update public.whatsapp_operator_reply_outbox o
  set
    status = 'SENDING',
    attempt_count = o.attempt_count + 1,
    lease_token = gen_random_uuid(),
    lease_expires_at = statement_timestamp() + make_interval(secs => v_lease),
    updated_at = statement_timestamp()
  from candidate
  where o.id = candidate.id
  returning o.* into v_result;

  if not found then
    return null;
  end if;

  insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
  values (
    v_result.id,
    'CLAIMED',
    jsonb_build_object(
      'worker_id', v_worker,
      'attempt', v_result.attempt_count,
      'lease_token', v_result.lease_token,
      'message_origin', v_result.message_origin
    )
  );

  return v_result;
end;
$$;

create or replace function public.complete_whatsapp_operator_reply(
  p_reply_id uuid,
  p_lease_token uuid,
  p_provider text,
  p_provider_message_id text
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;
  update public.whatsapp_operator_reply_outbox
  set
    status = 'ACCEPTED',
    provider = btrim(p_provider),
    provider_message_id = btrim(p_provider_message_id),
    accepted_at = statement_timestamp(),
    lease_token = null,
    lease_expires_at = null,
    last_error_code = null,
    last_error_detail = null,
    updated_at = statement_timestamp()
  where id = p_reply_id
    and status = 'SENDING'
    and lease_token = p_lease_token
    and lease_expires_at > statement_timestamp()
  returning * into v_result;
  if not found then
    raise exception 'WA5_STALE_OR_INVALID_LEASE';
  end if;
  insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
  values (
    v_result.id,
    'PROVIDER_ACCEPTED',
    jsonb_build_object(
      'provider', p_provider,
      'provider_message_id', p_provider_message_id,
      'message_origin', v_result.message_origin
    )
  );
  return v_result;
end;
$$;

create or replace function public.fail_whatsapp_operator_reply(
  p_reply_id uuid,
  p_lease_token uuid,
  p_error_code text,
  p_error_detail text,
  p_acceptance_unknown boolean default false
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;
  update public.whatsapp_operator_reply_outbox
  set
    status = case
      when p_acceptance_unknown then 'ACCEPTANCE_UNKNOWN'
      when attempt_count < 5 then 'FAILED_RETRYABLE'
      else 'FAILED_FINAL'
    end,
    next_attempt_at = case
      when p_acceptance_unknown then 'infinity'::timestamptz
      else statement_timestamp()
        + make_interval(secs => least(3600, 30 * (2 ^ greatest(attempt_count - 1, 0))::integer))
    end,
    lease_token = null,
    lease_expires_at = null,
    last_error_code = btrim(p_error_code),
    last_error_detail = left(p_error_detail, 1000),
    updated_at = statement_timestamp()
  where id = p_reply_id
    and status = 'SENDING'
    and lease_token = p_lease_token
  returning * into v_result;
  if not found then
    raise exception 'WA5_STALE_OR_INVALID_LEASE';
  end if;
  insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
  values (
    v_result.id,
    case when p_acceptance_unknown then 'PROVIDER_ACCEPTANCE_UNKNOWN' else 'SEND_FAILED' end,
    jsonb_build_object(
      'error_code', p_error_code,
      'retryable', v_result.status = 'FAILED_RETRYABLE',
      'message_origin', v_result.message_origin
    )
  );
  return v_result;
end;
$$;

revoke all on function public.quarantine_whatsapp_operator_reply(uuid, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.disposition_historical_gate3_stale_autonomous_receipts()
  from public, anon, authenticated;
grant execute on function public.quarantine_whatsapp_operator_reply(uuid, text, jsonb)
  to service_role;
grant execute on function public.disposition_historical_gate3_stale_autonomous_receipts()
  to service_role;

comment on function public.quarantine_whatsapp_operator_reply(uuid, text, jsonb) is
  'Core-authoritative quarantine for governed operator replies. Preserves audit linkage and prevents consumer claim/send.';
comment on function public.disposition_historical_gate3_stale_autonomous_receipts() is
  'Idempotently quarantines stale Gate-3-generated core-c non-order receipts that must never be sent to customers.';
comment on function public.claim_whatsapp_operator_reply(text, uuid, integer) is
  'Exclusive durable claim for operator-reply outbox rows, including expired-lease recovery; excludes quarantined and terminal rows.';

-- Apply stale receipt disposition when matching rows exist (production Gate-3 backlog).
do $$
declare
  v_row public.whatsapp_operator_reply_outbox%rowtype;
  v_prior_status text;
begin
  for v_row in
    select *
    from public.whatsapp_operator_reply_outbox
    where status in ('QUEUED', 'SENDING', 'FAILED_RETRYABLE')
      and provider_message_id is null
      and idempotency_key like 'core-c:non-order-receipt:%'
      and message_origin = 'AUTONOMOUS'
    order by created_at
    for update
  loop
    v_prior_status := v_row.status;
    update public.whatsapp_operator_reply_outbox
    set
      status = 'QUARANTINED',
      quarantine_reason = 'HISTORICAL_GATE3_STALE_AUTONOMOUS_RECEIPT',
      quarantined_at = statement_timestamp(),
      quarantine_evidence = jsonb_build_object(
        'disposition', 'DO_NOT_SEND',
        'gate', 'Gate-3-backlog-drain',
        'idempotency_key', v_row.idempotency_key,
        'packet_id', v_row.packet_id,
        'created_at', v_row.created_at
      ),
      lease_token = null,
      lease_expires_at = null,
      next_attempt_at = 'infinity'::timestamptz,
      updated_at = statement_timestamp()
    where id = v_row.id;

    insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
    values (
      v_row.id,
      'QUARANTINED',
      jsonb_build_object(
        'reason', 'HISTORICAL_GATE3_STALE_AUTONOMOUS_RECEIPT',
        'prior_status', v_prior_status,
        'message_origin', v_row.message_origin,
        'idempotency_key', v_row.idempotency_key,
        'disposition', 'DO_NOT_SEND',
        'gate', 'Gate-3-backlog-drain'
      )
    );
  end loop;
end;
$$;

commit;
