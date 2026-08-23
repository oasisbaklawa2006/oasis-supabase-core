-- CORE-C: governed customer communication, clarification/resume loop, and non-order accountability.
-- Reuses WA-5 outbound, WA-3 clarification questions, PR #102 cross-packet lineage,
-- CASE_CONTEXT dispatch, CORE-A/CORE-B autonomy without a second reply or clarification system.
begin;

-- -----------------------------------------------------------------------------
-- 1. Service actor + governed autonomous outbound (WA-5 reuse)
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_system_actor_id()
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select u.id
  from public.users u
  where coalesce(u.is_active, true)
    and u.deleted_at is null
  order by case when u.role = 'admin' then 0 else 1 end, u.created_at
  limit 1;
$$;

revoke all on function public.whatsapp_core_c_system_actor_id() from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_system_actor_id() to service_role;

create or replace function public.wa6_guard_operator_reply_disclosure()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inferred text[];
  v_required text[];
  v_company_id uuid;
begin
  if current_setting('app.core_c_governed_outbound', true) = 'on' then
    v_inferred := public.wa6_infer_commercial_disclosure(new.message_body);
    select array_agg(distinct scope order by scope)
    into v_required
    from unnest(coalesce(new.disclosure_scope, '{}') || coalesce(v_inferred, '{}')) scope
    where btrim(scope) <> '';
    new.disclosure_scope := coalesce(v_required, '{}');
    return new;
  end if;

  v_inferred := public.wa6_infer_commercial_disclosure(new.message_body);
  select array_agg(distinct scope order by scope)
  into v_required
  from unnest(coalesce(new.disclosure_scope, '{}') || coalesce(v_inferred, '{}')) scope;
  new.disclosure_scope := coalesce(v_required, '{}');
  if cardinality(new.disclosure_scope) = 0 then
    return new;
  end if;
  if new.potential_order_id is null then
    raise exception 'WA6_COMMERCIAL_DISCLOSURE_REQUIRES_GOVERNED_ORDER';
  end if;
  select case
    when r.resolution_state in ('resolved', 'operator_confirmed')
      and r.resolved_value->>'company_id' ~ '^[0-9a-fA-F-]{36}$'
      then (r.resolved_value->>'company_id')::uuid
  end
  into v_company_id
  from public.whatsapp_order_field_resolutions r
  where r.potential_order_id = new.potential_order_id
    and r.field_key = 'client_identity';
  if v_company_id is null then
    raise exception 'WA6_VERIFIED_CUSTOMER_REQUIRED';
  end if;
  if not exists (
    select 1
    from public.whatsapp_sender_commercial_authorizations a
    where a.contact_id = new.contact_id
      and a.company_id = v_company_id
      and a.status = 'ACTIVE'
      and a.valid_until > now()
      and new.disclosure_scope <@ a.disclosure_scope
  ) then
    raise exception 'WA6_DISCLOSURE_SCOPE_NOT_AUTHORIZED';
  end if;
  return new;
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
  v_actor uuid;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_phone text;
  v_body text := btrim(coalesce(p_message_body, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_purpose text := upper(btrim(coalesce(p_purpose, '')));
  v_scope text[];
  v_result public.whatsapp_operator_reply_outbox%rowtype;
  v_inferred text[];
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

  v_actor := public.whatsapp_core_c_system_actor_id();
  if v_actor is null then
    raise exception 'CORE_C_SYSTEM_ACTOR_UNAVAILABLE';
  end if;

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
  if v_purpose in ('PROMOTED_ORDER_ACK', 'NON_ORDER_RECEIPT', 'CASE_RECEIPT')
     and cardinality(v_inferred) > 0 then
    raise exception 'CORE_C_UNSAFE_OUTBOUND_DISCLOSURE';
  end if;
  if v_purpose = 'AUTONOMY_CLARIFICATION' and v_inferred && array[
    'customer_pricing', 'account_balance', 'payment_terms', 'draft_order', 'sales_order'
  ]::text[] then
    raise exception 'CORE_C_CLARIFICATION_DISCLOSURE_FORBIDDEN';
  end if;

  select coalesce(array_agg(distinct scope order by scope), '{}'::text[])
  into v_scope
  from unnest(coalesce(p_disclosure_scope, '{}'::text[]) || v_inferred) scope
  where btrim(scope) <> '';

  perform set_config('app.core_c_governed_outbound', 'on', true);
  insert into public.whatsapp_operator_reply_outbox(
    packet_id, contact_id, potential_order_id, clarification_task_id,
    recipient_phone_e164, message_body, message_type, disclosure_scope,
    idempotency_key, created_by
  ) values (
    p_packet_id, p_contact_id, p_potential_order_id, null,
    v_phone, v_body, 'TEXT', v_scope, v_key, v_actor
  )
  on conflict (packet_id, idempotency_key) do update
  set idempotency_key = excluded.idempotency_key
  returning * into v_result;
  perform set_config('app.core_c_governed_outbound', 'off', true);

  insert into public.whatsapp_operator_reply_events(reply_id, event_type, actor_id, evidence)
  values (
    v_result.id,
    'CORE_C_ENQUEUED_OR_REPLAYED',
    v_actor,
    jsonb_build_object(
      'purpose', v_purpose,
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
      jsonb_build_object('purpose', v_purpose, 'reply_id', v_result.id, 'status', v_result.status),
      jsonb_build_object('message_body', v_body, 'clarification_id', p_clarification_id)
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  return v_result;
exception
  when others then
    perform set_config('app.core_c_governed_outbound', 'off', true);
    raise;
end;
$$;

revoke all on function public.enqueue_governed_whatsapp_autonomous_reply(
  uuid, uuid, text, text, text, text, uuid, uuid, uuid, text[]
) from public, anon, authenticated;
grant execute on function public.enqueue_governed_whatsapp_autonomous_reply(
  uuid, uuid, text, text, text, text, uuid, uuid, uuid, text[]
) to service_role;

-- -----------------------------------------------------------------------------
-- 2. Clarification field derivation + sender authorization
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_derive_clarification_field(
  p_blocking_reasons text[]
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select case
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like 'ambiguous_customer%' or r = 'ambiguous_customer_match'
    ) then 'CUSTOMER'
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like '%branch%'
    ) then 'BRANCH'
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like '%product%' or r like '%sku%'
    ) then 'PRODUCT'
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like '%quantity%'
    ) then 'QUANTITY'
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like '%unit%'
    ) then 'UOM_PACK'
    when exists (
      select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
      where r like '%conflict%' or r like '%contradict%'
    ) then 'CORRECTION'
    else 'PRODUCT'
  end;
$$;

create or replace function public.whatsapp_core_c_minimum_clarification_question(
  p_field_name text,
  p_ai_draft_reply text default null
)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_field text := upper(btrim(coalesce(p_field_name, '')));
  v_draft text := btrim(coalesce(p_ai_draft_reply, ''));
  v_wa3_key text;
  v_question text;
begin
  v_wa3_key := case v_field
    when 'CUSTOMER' then 'client_identity'
    when 'BRANCH' then 'delivery_address'
    when 'PRODUCT' then 'product'
    when 'QUANTITY' then 'quantity'
    when 'UOM_PACK' then 'unit_packaging'
    when 'CORRECTION' then 'quantity'
    else 'product'
  end;
  v_question := public.wa3_clarification_question(v_wa3_key);
  if v_question is null then
    v_question := 'Which exact product and quantity do you require?';
  end if;
  if length(v_draft) >= 8
     and length(v_draft) <= 4000
     and coalesce(public.wa6_infer_commercial_disclosure(v_draft), '{}'::text[]) = '{}'::text[]
     and lower(v_draft) not in ('please clarify', 'kindly clarify', 'confirm', 'please confirm') then
    return v_draft;
  end if;
  return v_question;
end;
$$;

create or replace function public.whatsapp_core_c_ensure_submitting_sender_authorization(
  p_case_id uuid
)
returns public.whatsapp_case_recipient_authorizations
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid;
  v_identity public.whatsapp_case_identities%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_actor := public.whatsapp_core_c_system_actor_id();
  select * into v_identity
  from public.whatsapp_case_identities
  where case_id = p_case_id and identity_role = 'SUBMITTING_SENDER';
  if not found then
    raise exception 'CORE_C_SUBMITTING_SENDER_IDENTITY_REQUIRED';
  end if;

  select * into v_auth
  from public.whatsapp_case_recipient_authorizations
  where case_id = p_case_id
    and identity_id = v_identity.id
    and revoked_at is null
    and may_receive_clarification
  order by verified_at desc
  limit 1;
  if found then
    return v_auth;
  end if;

  insert into public.whatsapp_case_recipient_authorizations(
    case_id, identity_id, disclosure_scope, may_receive_clarification,
    may_confirm_commercial_scope, verification_method, verified_by, verified_at,
    correlation_key
  ) values (
    p_case_id, v_identity.id, '{}'::text[], true, false,
    'OPERATOR_VERIFIED', v_actor, statement_timestamp(),
    'core-c:auto-sender-auth:' || v_identity.id::text
  )
  on conflict (case_id, identity_id, correlation_key) do nothing
  returning * into v_auth;

  if v_auth.id is null then
    select * into v_auth
    from public.whatsapp_case_recipient_authorizations
    where case_id = p_case_id
      and identity_id = v_identity.id
      and correlation_key = 'core-c:auto-sender-auth:' || v_identity.id::text;
  end if;
  return v_auth;
end;
$$;

revoke all on function public.whatsapp_core_c_ensure_submitting_sender_authorization(uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_ensure_submitting_sender_authorization(uuid)
  to service_role;

-- -----------------------------------------------------------------------------
-- 3. CLARIFICATION_REQUIRED outbound + PROMOTED acknowledgement
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_enqueue_autonomy_clarification_v1(
  p_autonomy_decision_id uuid,
  p_draft_reply text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_field text;
  v_question text;
  v_key text;
  v_clarification public.whatsapp_case_clarifications%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_revision bigint;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  select * into v_decision
  from public.whatsapp_order_autonomy_decisions
  where id = p_autonomy_decision_id;
  if not found or v_decision.autonomy_outcome <> 'CLARIFICATION_REQUIRED' then
    raise exception 'CORE_C_CLARIFICATION_DECISION_REQUIRED';
  end if;
  if v_decision.case_id is null then
    raise exception 'CORE_C_CASE_REQUIRED';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id = v_decision.case_id for update;
  select * into v_packet from public.whatsapp_message_packets where id = v_decision.packet_id;
  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;

  v_revision := coalesce(v_case.context_revision, 0);
  v_key := 'core-c:clarification:' || v_decision.interpretation_id::text || ':rev:' || v_revision::text;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_case.id and correlation_key = 'core-c-clarification:' || v_key
  ) then
    select * into v_clarification
    from public.whatsapp_case_clarifications
    where case_id = v_case.id and correlation_key = 'core-c:' || v_key;
    select * into v_reply
    from public.whatsapp_operator_reply_outbox
    where packet_id = v_decision.packet_id and idempotency_key = v_key;
    return jsonb_build_object(
      'case_id', v_case.id,
      'clarification_id', v_clarification.id,
      'reply_id', v_reply.id,
      'idempotent_replay', true
    );
  end if;

  v_auth := public.whatsapp_core_c_ensure_submitting_sender_authorization(v_case.id);
  v_field := public.whatsapp_core_c_derive_clarification_field(v_decision.blocking_reasons);
  v_question := public.whatsapp_core_c_minimum_clarification_question(v_field, p_draft_reply);

  insert into public.whatsapp_case_clarifications(
    case_id, field_name, question, recipient_authorization_id, status,
    due_at, next_follow_up_at, asked_by, correlation_key
  ) values (
    v_case.id, v_field, v_question, v_auth.id, 'OPEN',
    statement_timestamp() + interval '1 day',
    statement_timestamp() + interval '1 day',
    public.whatsapp_core_c_system_actor_id(),
    'core-c:' || v_key
  ) returning * into v_clarification;

  v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
    v_decision.packet_id, v_contact.id,
    '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
    v_question, v_key, 'AUTONOMY_CLARIFICATION',
    v_decision.potential_order_id, v_case.id, v_clarification.id, '{}'::text[]
  );

  update public.whatsapp_case_clarifications
  set source_outbound_message_id = v_reply.id
  where id = v_clarification.id;

  update public.whatsapp_communication_cases
  set status = 'AWAITING_CUSTOMER',
      next_action = 'Await customer clarification: ' || v_field,
      next_action_due_at = statement_timestamp() + interval '1 day',
      updated_at = statement_timestamp()
  where id = v_case.id;

  insert into public.whatsapp_case_events(
    case_id, event_type, actor_type, correlation_key, resulting_state, metadata
  ) values (
    v_case.id, 'AUTONOMOUS_CLARIFICATION_RELEASED', 'SYSTEM',
    'core-c-clarification:' || v_key,
    jsonb_build_object(
      'status', 'AWAITING_CUSTOMER',
      'field_name', v_field,
      'context_revision', v_revision
    ),
    jsonb_build_object(
      'autonomy_decision_id', v_decision.id,
      'clarification_id', v_clarification.id,
      'reply_id', v_reply.id,
      'question', v_question
    )
  );

  return jsonb_build_object(
    'case_id', v_case.id,
    'clarification_id', v_clarification.id,
    'reply_id', v_reply.id,
    'field_name', v_field,
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.whatsapp_enqueue_autonomy_clarification_v1(uuid, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_enqueue_autonomy_clarification_v1(uuid, text)
  to service_role;

create or replace function public.whatsapp_build_promoted_order_ack_message(
  p_order_number text default null
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select case
    when nullif(btrim(p_order_number), '') is null then
      'Thank you. We have received your order request and registered it for processing. Our team will contact you if anything else is required.'
    else
      'Thank you. We have received your order request and registered it for processing. Reference: '
      || btrim(p_order_number)
      || '. Our team will contact you if anything else is required.'
  end;
$$;

create or replace function public.whatsapp_enqueue_promoted_order_acknowledgement_v1(
  p_autonomy_decision_id uuid,
  p_order_number text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_projection public.whatsapp_order_autonomy_draft_executions%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_body text;
  v_key text;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  select * into v_projection
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id
    and execution_status = 'PROMOTED';
  if not found then
    raise exception 'CORE_C_PROMOTED_EXECUTION_REQUIRED';
  end if;

  v_key := 'core-c:promoted-ack:' || p_autonomy_decision_id::text;
  v_body := public.whatsapp_build_promoted_order_ack_message(p_order_number);

  select * into v_contact
  from public.whatsapp_contacts c
  join public.whatsapp_message_packets p on p.contact_id = c.id
  where p.id = v_projection.packet_id;

  v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
    v_projection.packet_id, v_contact.id,
    '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
    v_body, v_key, 'PROMOTED_ORDER_ACK',
    v_projection.potential_order_id, v_projection.case_id, null, '{}'::text[]
  );

  return jsonb_build_object(
    'reply_id', v_reply.id,
    'idempotency_key', v_key,
    'idempotent_replay', exists (
      select 1 from public.whatsapp_operator_reply_events e
      where e.reply_id = v_reply.id
        and e.event_type = 'CORE_C_ENQUEUED_OR_REPLAYED'
        and e.created_at < statement_timestamp() - interval '1 millisecond'
    )
  );
end;
$$;

revoke all on function public.whatsapp_enqueue_promoted_order_acknowledgement_v1(uuid, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_enqueue_promoted_order_acknowledgement_v1(uuid, text)
  to service_role;

-- -----------------------------------------------------------------------------
-- 4. Cross-packet answer correlation + automatic clarification resolve
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_resolve_correlated_clarification_v1(
  p_answer_evidence_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid;
  v_evidence public.whatsapp_clarification_answer_evidence%rowtype;
  v_clarification public.whatsapp_case_clarifications%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_message public.whatsapp_messages%rowtype;
  v_answer text;
  v_remaining integer;
  v_next_due timestamptz;
  v_key text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_actor := public.whatsapp_core_c_system_actor_id();
  select * into v_evidence
  from public.whatsapp_clarification_answer_evidence
  where id = p_answer_evidence_id;
  if not found then
    raise exception 'CORE_C_ANSWER_EVIDENCE_REQUIRED';
  end if;

  select * into v_clarification
  from public.whatsapp_case_clarifications
  where id = v_evidence.clarification_request_id
  for update;
  if not found then
    raise exception 'CORE_C_CLARIFICATION_NOT_FOUND';
  end if;

  v_key := 'core-c:auto-resolve:' || v_evidence.id::text;
  if v_clarification.status = 'ANSWERED' then
    return jsonb_build_object(
      'clarification_id', v_clarification.id,
      'idempotent_replay', true
    );
  end if;
  if v_clarification.status <> 'OPEN' then
    raise exception 'CORE_C_CLARIFICATION_NOT_OPEN';
  end if;

  select * into v_case
  from public.whatsapp_communication_cases
  where id = v_clarification.case_id
  for update;

  select * into v_auth
  from public.whatsapp_case_recipient_authorizations
  where id = v_clarification.recipient_authorization_id
    and case_id = v_case.id;
  if not found or v_auth.revoked_at is not null then
    raise exception 'CORE_C_RECIPIENT_AUTH_INACTIVE';
  end if;

  select * into v_message
  from public.whatsapp_messages
  where id = v_evidence.answer_whatsapp_message_id
    and lower(direction) = 'inbound';
  if not found then
    raise exception 'CORE_C_ANSWER_MESSAGE_REQUIRED';
  end if;
  if v_message.created_at < v_clarification.asked_at then
    raise exception 'CORE_C_ANSWER_BEFORE_QUESTION';
  end if;

  v_answer := btrim(coalesce(v_message.content, ''));
  if length(v_answer) < 1 then
    raise exception 'CORE_C_ANSWER_TEXT_REQUIRED';
  end if;
  if lower(v_answer) in ('yes', 'y', 'ok', 'okay', 'confirmed', 'haan', 'ha') then
    raise exception 'CORE_C_AMBIGUOUS_AFFIRMATION';
  end if;

  update public.whatsapp_case_clarifications
  set status = 'ANSWERED',
      answer_text = v_answer,
      answer_payload = jsonb_build_object(
        'source', 'CORE_C_AUTO_RESUME',
        'answer_evidence_id', v_evidence.id,
        'correlation_method', v_evidence.correlation_method
      ),
      answer_source_message_id = v_message.id,
      answered_by_identity_id = v_auth.identity_id,
      confirmed_by = v_actor,
      answered_at = statement_timestamp(),
      next_follow_up_at = null
  where id = v_clarification.id
  returning * into v_clarification;

  select count(*), min(due_at)
  into v_remaining, v_next_due
  from public.whatsapp_case_clarifications
  where case_id = v_case.id and status = 'OPEN';

  update public.whatsapp_communication_cases
  set status = case when v_remaining = 0 then 'OPEN' else 'NEEDS_CLARIFICATION' end,
      next_action = case
        when v_remaining = 0 then 'Resume governed autonomy after customer clarification'
        else 'Resolve remaining customer clarifications'
      end,
      next_action_due_at = v_next_due,
      updated_at = statement_timestamp()
  where id = v_case.id;

  insert into public.whatsapp_case_events(
    case_id, event_type, actor_type, correlation_key, resulting_state, metadata
  ) values (
    v_case.id, 'AUTONOMOUS_CLARIFICATION_ANSWER_RESOLVED', 'SYSTEM',
    v_key,
    jsonb_build_object(
      'clarification_id', v_clarification.id,
      'field_name', v_clarification.field_name,
      'status', 'ANSWERED'
    ),
    jsonb_build_object(
      'answer_evidence_id', v_evidence.id,
      'answer_whatsapp_message_id', v_message.id,
      'remaining_open_clarifications', v_remaining
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', v_case.id,
    'clarification_id', v_clarification.id,
    'remaining_open_clarifications', v_remaining,
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.whatsapp_core_c_resolve_correlated_clarification_v1(uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_resolve_correlated_clarification_v1(uuid)
  to service_role;

create or replace function public.whatsapp_process_inbound_whatsapp_continuation_v1(
  p_inbound_whatsapp_message_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_evidence public.whatsapp_clarification_answer_evidence%rowtype;
  v_resolve jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  begin
    v_evidence := public.whatsapp_correlate_clarification_answer(p_inbound_whatsapp_message_id);
  exception
    when others then
      return jsonb_build_object('correlated', false, 'reason', sqlerrm);
  end;

  v_resolve := public.whatsapp_core_c_resolve_correlated_clarification_v1(v_evidence.id);

  return jsonb_build_object(
    'correlated', true,
    'answer_evidence_id', v_evidence.id,
    'clarification_resolution', v_resolve,
    'case_context_dispatched', true
  );
end;
$$;

revoke all on function public.whatsapp_process_inbound_whatsapp_continuation_v1(uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_process_inbound_whatsapp_continuation_v1(uuid)
  to service_role;

create or replace function public.whatsapp_inbound_continuation_trigger()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if lower(new.direction) = 'inbound'
     and new.provider_message_id is not null
     and nullif(btrim(new.provider_message_id), '') is not null then
    perform public.whatsapp_process_inbound_whatsapp_continuation_v1(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists whatsapp_inbound_core_c_continuation on public.whatsapp_messages;
create trigger whatsapp_inbound_core_c_continuation
  after insert on public.whatsapp_messages
  for each row execute function public.whatsapp_inbound_continuation_trigger();

-- -----------------------------------------------------------------------------
-- 5. Non-order accountable resolution + correction safety
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_non_order_sla_interval(p_case_type text)
returns interval
language sql
immutable
set search_path = pg_catalog, public
as $$
  select case upper(btrim(coalesce(p_case_type, '')))
    when 'COMPLAINT' then interval '4 hours'
    when 'PAYMENT_ADVICE' then interval '8 hours'
    when 'ACCOUNT_QUERY' then interval '8 hours'
    when 'DISPATCH' then interval '4 hours'
    when 'ENQUIRY' then interval '24 hours'
    when 'SPECIFICATION' then interval '24 hours'
    else interval '24 hours'
  end;
$$;

create or replace function public.whatsapp_core_c_safe_non_order_receipt(
  p_case_type text,
  p_primary_department text,
  p_case_id uuid
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select format(
    'Thank you for contacting Oasis Baklawa. We have received your %s and routed it to our %s team for review. Case reference: %s. A team member will respond through this channel.',
    lower(replace(upper(btrim(coalesce(p_case_type, 'message'))), '_', ' ')),
    coalesce(nullif(upper(btrim(p_primary_department)), ''), 'CUSTOMER_SERVICE'),
    left(p_case_id::text, 8)
  );
$$;

create or replace function public.whatsapp_apply_non_order_case_governance_v1(
  p_case_id uuid,
  p_interpretation_id uuid,
  p_intent text,
  p_primary_department text,
  p_reply_clearance text default null,
  p_draft_reply text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_team text;
  v_due timestamptz;
  v_key text;
  v_body text;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_allow_receipt boolean := false;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id = p_case_id for update;
  if not found or v_case.status in ('CLOSED', 'CANCELLED') then
    raise exception 'CORE_C_ACTIVE_CASE_REQUIRED';
  end if;
  if v_case.case_type in ('ORDER') and upper(btrim(p_intent)) in ('ORDER', 'NEW_ORDER') then
    return jsonb_build_object('skipped', true, 'reason', 'commercial_order_path');
  end if;

  v_team := coalesce(
    nullif(upper(btrim(p_primary_department)), ''),
    case v_case.case_type
      when 'COMPLAINT' then 'QUALITY'
      when 'PAYMENT_ADVICE' then 'FINANCE'
      when 'ACCOUNT_QUERY' then 'FINANCE'
      when 'DISPATCH' then 'DISPATCH'
      when 'ENQUIRY' then 'SALES'
      when 'SPECIFICATION' then 'SALES'
      else 'CUSTOMER_SERVICE'
    end
  );
  v_due := statement_timestamp() + public.whatsapp_core_c_non_order_sla_interval(v_case.case_type);

  update public.whatsapp_communication_cases
  set accountable_team = v_team,
      accountability_status = case
        when accountability_status = 'UNASSIGNED' then 'ASSIGNED'
        else accountability_status
      end,
      next_action = coalesce(
        nullif(btrim(v_case.next_action), ''),
        'Accountable ' || v_team || ' review required'
      ),
      next_action_due_at = coalesce(v_case.next_action_due_at, v_due),
      status = case when status = 'NEEDS_IDENTITY' then 'OPEN' else status end,
      updated_at = statement_timestamp()
  where id = p_case_id
  returning * into v_case;

  insert into public.whatsapp_case_department_tasks(
    case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
  ) values (
    p_case_id, v_team, 'ACCOUNTABLE_RESPONSE_OWNER',
    'Governed non-order case requires accountable department action.',
    'OPEN', v_due, 'core-c-non-order:' || p_interpretation_id::text,
    public.whatsapp_core_c_system_actor_id()
  )
  on conflict (case_id, correlation_key) do nothing;

  v_allow_receipt := upper(btrim(coalesce(p_reply_clearance, ''))) in (
    'SAFE_TO_SEND_AUTOMATICALLY', 'CLARIFICATION_REQUIRED'
  ) or v_case.case_type in ('ENQUIRY', 'DELIVERY_QUERY', 'DISPATCH', 'SPECIFICATION');

  if v_allow_receipt
     and v_case.case_type in (
       'ENQUIRY', 'COMPLAINT', 'PAYMENT_ADVICE', 'ACCOUNT_QUERY',
       'DISPATCH', 'SPECIFICATION', 'UNCLASSIFIED'
     ) then
    v_key := 'core-c:non-order-receipt:' || p_interpretation_id::text;
    if not exists (
      select 1 from public.whatsapp_case_events
      where case_id = p_case_id and correlation_key = 'core-c-receipt:' || v_key
    ) then
      select * into v_packet from public.whatsapp_message_packets where id = v_case.packet_id;
      select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
      v_body := public.whatsapp_core_c_safe_non_order_receipt(v_case.case_type, v_team, v_case.id);
      if coalesce(public.wa6_infer_commercial_disclosure(v_body), '{}'::text[]) = '{}'::text[] then
        v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
          v_case.packet_id, v_contact.id,
          '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
          v_body, v_key, 'NON_ORDER_RECEIPT',
          null, v_case.id, null, '{}'::text[]
        );
        insert into public.whatsapp_case_events(
          case_id, event_type, actor_type, correlation_key, metadata
        ) values (
          p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_SENT', 'SYSTEM',
          'core-c-receipt:' || v_key,
          jsonb_build_object('reply_id', v_reply.id, 'case_type', v_case.case_type)
        )
        on conflict (case_id, correlation_key) do nothing;
      end if;
    end if;
  end if;

  insert into public.whatsapp_case_events(
    case_id, event_type, actor_type, correlation_key, resulting_state, metadata
  ) values (
    p_case_id, 'NON_ORDER_GOVERNANCE_APPLIED', 'SYSTEM',
    'core-c-non-order-governance:' || p_interpretation_id::text,
    jsonb_build_object(
      'accountable_team', v_team,
      'case_type', v_case.case_type,
      'intent', upper(btrim(p_intent))
    ),
    jsonb_build_object('due_at', v_due, 'interpretation_id', p_interpretation_id)
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', p_case_id,
    'accountable_team', v_team,
    'next_action_due_at', v_due,
    'receipt_sent', v_reply.id is not null
  );
end;
$$;

revoke all on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) to service_role;

create or replace function public.whatsapp_core_c_guard_post_so_correction_v1(
  p_potential_order_id uuid,
  p_intent text,
  p_has_corrections boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_po public.whatsapp_potential_orders%rowtype;
begin
  if p_potential_order_id is null or not coalesce(p_has_corrections, false) then
    return jsonb_build_object('blocked', false);
  end if;

  select * into v_po from public.whatsapp_potential_orders where id = p_potential_order_id;
  if not found then
    return jsonb_build_object('blocked', false);
  end if;

  if v_po.sales_order_id is not null then
    return jsonb_build_object(
      'blocked', true,
      'route', 'ORDER_AMENDMENT_GOVERNED',
      'sales_order_id', v_po.sales_order_id,
      'reason', 'correction_after_so_requires_amendment_process'
    );
  end if;

  return jsonb_build_object('blocked', false);
end;
$$;

revoke all on function public.whatsapp_core_c_guard_post_so_correction_v1(uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_guard_post_so_correction_v1(uuid, text, boolean)
  to service_role;

-- -----------------------------------------------------------------------------
-- 6. PROMOTED finalization hook (exactly-once acknowledgement)
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_finalize_autonomous_so_promotion_v1(
  p_autonomy_decision_id uuid,
  p_draft_id uuid,
  p_promoted_order_id uuid,
  p_order_number text,
  p_idempotency_key text,
  p_governed_facts jsonb,
  p_readiness jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_projection public.whatsapp_order_autonomy_draft_executions%rowtype;
begin
  select * into v_projection
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  perform public.whatsapp_append_autonomy_draft_execution_event(
    p_autonomy_decision_id, 'PROMOTED',
    v_projection.potential_order_id, v_projection.case_id, v_projection.packet_id, v_projection.interpretation_id,
    p_draft_id, p_promoted_order_id, null,
    p_idempotency_key,
    p_governed_facts, p_readiness
  );

  if v_projection.case_id is not null then
    insert into public.whatsapp_case_events(case_id, event_type, actor_type, correlation_key, resulting_state, metadata)
    values (
      v_projection.case_id, 'AUTONOMOUS_SO_PROMOTED', 'SYSTEM',
      'core-b-promote:' || v_projection.interpretation_id::text,
      jsonb_build_object('sales_order_draft_id', p_draft_id, 'promoted_order_id', p_promoted_order_id),
      jsonb_build_object('order_number', p_order_number, 'autonomous', true)
    )
    on conflict (case_id, correlation_key) do nothing;

    update public.whatsapp_communication_cases
    set next_action = 'SO_CREATED_AWAITING_FULFILLMENT',
        updated_at = statement_timestamp()
    where id = v_projection.case_id;
  end if;

  perform set_config('app.wa1_governed_mutation', 'on', true);
  update public.whatsapp_potential_orders
  set state = 'CONVERTED',
      disposition = 'CONVERTED',
      sales_order_draft_id = p_draft_id,
      sales_order_id = p_promoted_order_id,
      next_action = 'ORDER_CREATED',
      updated_at = statement_timestamp()
  where id = v_projection.potential_order_id;
  perform set_config('app.wa1_governed_mutation', 'off', true);

  perform public.whatsapp_enqueue_promoted_order_acknowledgement_v1(
    p_autonomy_decision_id, p_order_number
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Materialize bridge: CORE-C communication continuation
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_materialize_packet_ai_case(
  p_packet_id uuid,
  p_interpretation_id uuid,
  p_job_id uuid default null,
  p_lease_token uuid default null,
  p_packet_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case_type text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_recommended_action text;
  v_primary_department text;
  v_contributors jsonb;
  v_reply_clearance text;
  v_draft_reply text;
  v_ambiguity_count integer := 0;
  v_event_key text;
  v_correction_guard jsonb;
  v_has_corrections boolean := false;
  v_clarification jsonb;
  v_non_order jsonb;
  v_autonomy_outcome text := null;
  v_human_decision_required boolean := true;
  v_autonomy jsonb := '{}'::jsonb;
  v_draft_execution jsonb;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  if not found then raise exception 'WhatsApp packet not found'; end if;

  select * into v_ai from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id and packet_id = p_packet_id;
  if not found then raise exception 'packet AI interpretation not found for packet'; end if;

  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
  if not found then raise exception 'WhatsApp packet contact not found'; end if;

  v_conclusion := case when jsonb_typeof(v_ai.interpretation -> 'conclusion') = 'object'
    then v_ai.interpretation -> 'conclusion' else '{}'::jsonb end;
  v_intent := upper(coalesce(nullif(btrim(v_conclusion ->> 'intent'), ''), 'UNCLEAR'));
  v_case_type := case v_intent
    when 'NEW_ORDER' then 'ORDER' when 'ORDER' then 'ORDER'
    when 'AMENDMENT' then 'ORDER_CHANGE' when 'ORDER_CHANGE' then 'ORDER_CHANGE'
    when 'CANCELLATION' then 'CANCELLATION' when 'ENQUIRY' then 'ENQUIRY'
    when 'COMPLAINT' then 'COMPLAINT' when 'PAYMENT_ADVICE' then 'PAYMENT_ADVICE'
    when 'ACCOUNT_QUERY' then 'ACCOUNT_QUERY' when 'FINANCE' then 'ACCOUNT_QUERY'
    when 'DELIVERY_QUERY' then 'DISPATCH' when 'DISPATCH' then 'DISPATCH'
    when 'SPECIFICATION_QUERY' then 'SPECIFICATION' when 'SPECIFICATION' then 'SPECIFICATION'
    else 'UNCLASSIFIED' end;
  v_recommended_action := nullif(btrim(coalesce(v_conclusion ->> 'recommended_action', '')), '');
  v_primary_department := nullif(upper(btrim(coalesce(v_conclusion ->> 'primary_department', ''))), '');
  v_contributors := case when jsonb_typeof(v_conclusion -> 'contributor_departments') = 'array'
    then v_conclusion -> 'contributor_departments' else '[]'::jsonb end;
  v_reply_clearance := nullif(upper(btrim(coalesce(v_conclusion ->> 'reply_clearance', ''))), '');
  v_draft_reply := nullif(btrim(coalesce(v_conclusion ->> 'draft_reply', '')), '');
  v_ambiguity_count := case when jsonb_typeof(v_conclusion -> 'ambiguities') = 'array'
    then jsonb_array_length(v_conclusion -> 'ambiguities') else 0 end;
  v_has_corrections := jsonb_typeof(v_conclusion -> 'corrections') = 'array'
    and jsonb_array_length(v_conclusion -> 'corrections') > 0;

  insert into public.whatsapp_communication_cases (
    packet_id, case_type, status, next_action, source_channel, rule_version
  ) values (
    p_packet_id, v_case_type, 'NEEDS_IDENTITY', v_recommended_action, 'WHATSAPP', 'packet-ai-b2b-v1'
  )
  on conflict (packet_id) do update
  set case_type = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.case_type else public.whatsapp_communication_cases.case_type end,
      next_action = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.next_action else public.whatsapp_communication_cases.next_action end,
      rule_version = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.rule_version else public.whatsapp_communication_cases.rule_version end,
      updated_at = statement_timestamp()
  returning * into v_case;

  insert into public.whatsapp_case_identities (
    case_id, identity_role, party_type, party_id, display_label, phone_e164, resolution_status, confidence, evidence
  ) values (
    v_case.id, 'SUBMITTING_SENDER', 'CONTACT', v_contact.id,
    coalesce(nullif(v_contact.customer_name, ''), nullif(v_contact.company_name, ''), v_contact.phone_number),
    v_contact.phone_number, 'SUGGESTED', 1.0,
    jsonb_build_array(jsonb_build_object('source', 'WHATSAPP_PACKET', 'packet_id', p_packet_id, 'contact_id', v_contact.id))
  )
  on conflict (case_id, identity_role) do update
  set party_type = excluded.party_type, party_id = excluded.party_id, display_label = excluded.display_label,
      phone_e164 = excluded.phone_e164, confidence = excluded.confidence, evidence = excluded.evidence
  where public.whatsapp_case_identities.resolution_status <> 'CONFIRMED';

  v_event_key := 'packet-ai:' || p_interpretation_id::text;
  insert into public.whatsapp_case_events (case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
  values (
    v_case.id, 'AI_CONCLUSION_READY', null, 'SYSTEM', v_event_key,
    jsonb_build_object('case_type', v_case_type, 'case_status', v_case.status),
    jsonb_build_object(
      'packet_id', p_packet_id, 'packet_ai_interpretation_id', p_interpretation_id,
      'content_fingerprint', v_ai.content_fingerprint, 'model_version', v_ai.model_version,
      'intent', v_intent, 'summary', coalesce(v_conclusion ->> 'summary', ''),
      'confidence', v_ai.interpretation -> 'confidence', 'ambiguity_count', v_ambiguity_count,
      'recommended_action', v_recommended_action, 'primary_department', v_primary_department,
      'contributor_departments', v_contributors, 'reply_clearance', v_reply_clearance,
      'draft_reply', v_draft_reply, 'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  v_correction_guard := public.whatsapp_core_c_guard_post_so_correction_v1(
    coalesce(
      public.whatsapp_case_potential_order_id(v_case.id),
      (
        select d.potential_order_id
        from public.whatsapp_order_autonomy_decisions d
        where d.case_id = v_case.id
        order by d.evaluated_at desc
        limit 1
      )
    ),
    v_intent,
    v_has_corrections
  );
  if coalesce((v_correction_guard ->> 'blocked')::boolean, false) then
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_type, correlation_key, metadata
    ) values (
      v_case.id, 'POST_SO_CORRECTION_ROUTED', 'SYSTEM',
      'core-c-post-so-correction:' || p_interpretation_id::text,
      v_correction_guard
    )
    on conflict (case_id, correlation_key) do nothing;
  else
    v_autonomy := public.whatsapp_evaluate_and_materialize_order_autonomy(
      p_packet_id, p_interpretation_id, p_job_id, p_lease_token, p_packet_revision
    );

    v_autonomy_outcome := v_autonomy->>'autonomy_outcome';
    v_human_decision_required := coalesce(
      (v_autonomy->>'human_decision_required')::boolean,
      (v_autonomy_outcome <> 'AUTO_ELIGIBLE')
    );

    v_draft_execution := null;
    if v_autonomy_outcome = 'AUTO_ELIGIBLE' and v_autonomy->>'decision_id' is not null then
      v_draft_execution := public.whatsapp_execute_autonomous_order_draft_v1(
        (v_autonomy->>'decision_id')::uuid,
        true
      );
    elsif v_autonomy_outcome = 'CLARIFICATION_REQUIRED' and v_autonomy->>'decision_id' is not null then
      v_clarification := public.whatsapp_enqueue_autonomy_clarification_v1(
        (v_autonomy->>'decision_id')::uuid,
        v_draft_reply
      );
    end if;
  end if;

  if v_intent not in ('ORDER', 'NEW_ORDER') or v_case.case_type <> 'ORDER' then
    v_non_order := public.whatsapp_apply_non_order_case_governance_v1(
      v_case.id, p_interpretation_id, v_intent, v_primary_department,
      v_reply_clearance, v_draft_reply
    );
  end if;

  select * into v_case from public.whatsapp_communication_cases where id = v_case.id;

  return jsonb_build_object(
    'case_id', v_case.id,
    'packet_id', p_packet_id,
    'interpretation_id', p_interpretation_id,
    'case_type', v_case.case_type,
    'status', v_case.status,
    'accountability_status', v_case.accountability_status,
    'autonomy_outcome', v_autonomy_outcome,
    'autonomy_decision_id', v_autonomy->>'decision_id',
    'governed_facts', v_autonomy->'governed_facts',
    'readiness', v_autonomy->'readiness',
    'draft_execution', v_draft_execution,
    'clarification', v_clarification,
    'non_order_governance', v_non_order,
    'post_so_correction_guard', v_correction_guard,
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', v_human_decision_required,
    'idempotent_replay', coalesce((v_autonomy->>'idempotent_replay')::boolean, false)
  );
end;
$$;

comment on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint) is
  'Service-role bridge from packet AI interpretation to governed autonomy (CORE-A/B) plus CORE-C communication continuation: auto-ack, clarification, answer resume, and non-order accountability.';

revoke all on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  to service_role;

commit;
