-- CORE-C authority closure: system principal, truthful provenance, WA-6 recipient classes,
-- team-only non-order routing, deterministic clarification, no AI authority bypass.
begin;

-- -----------------------------------------------------------------------------
-- 1. Explicit governed system principal (never impersonate a human employee)
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_system_principal_id()
returns uuid
language sql
immutable
set search_path = pg_catalog, public
as $$
  select 'c1000000-0000-4000-8000-000000000001'::uuid;
$$;

create or replace function public.whatsapp_core_c_ensure_system_principal()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_id uuid := public.whatsapp_core_c_system_principal_id();
begin
  insert into auth.users (id, email, aud, role)
  values (v_id, 'whatsapp-autonomous-system@system.oasis.internal', 'authenticated', 'authenticated')
  on conflict (id) do nothing;

  insert into public.users (id, email, full_name, role, is_active)
  values (
    v_id,
    'whatsapp-autonomous-system@system.oasis.internal',
    'WhatsApp Autonomous System Principal',
    'system_service',
    true
  )
  on conflict (id) do nothing;

  return v_id;
end;
$$;

drop function if exists public.whatsapp_core_c_system_actor_id();

revoke all on function public.whatsapp_core_c_system_principal_id() from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_system_principal_id() to service_role;
revoke all on function public.whatsapp_core_c_ensure_system_principal() from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_ensure_system_principal() to service_role;

select public.whatsapp_core_c_ensure_system_principal();

-- -----------------------------------------------------------------------------
-- 2. Truthful provenance authorization (no fabricated OPERATOR_VERIFIED)
-- -----------------------------------------------------------------------------

alter table public.whatsapp_case_recipient_authorizations
  drop constraint if exists whatsapp_case_recipient_authorization_verification_method_check;

alter table public.whatsapp_case_recipient_authorizations
  drop constraint if exists whatsapp_case_recipient_authorizations_verification_method_check;

alter table public.whatsapp_case_recipient_authorizations
  add constraint whatsapp_case_recipient_authorization_verification_method_check
  check (verification_method in (
    'CRM_MATCH', 'GST_MATCH', 'CALLBACK', 'OPERATOR_VERIFIED',
    'CUSTOMER_NOMINATED', 'PROVENANCE_VERIFIED'
  ));

-- -----------------------------------------------------------------------------
-- 3. Team routing without fictitious human owner assignment
-- -----------------------------------------------------------------------------

alter table public.whatsapp_communication_cases
  drop constraint if exists whatsapp_communication_cases_accountability_shape;

alter table public.whatsapp_communication_cases
  add constraint whatsapp_communication_cases_accountability_shape check (
    (
      accountability_status = 'UNASSIGNED'
      and accountable_owner_id is null
      and assigned_at is null
      and assigned_by is null
    )
    or (
      accountability_status in ('ASSIGNED', 'ESCALATED')
      and accountable_team is not null
      and accountable_owner_id is not null
      and assigned_at is not null
      and assigned_by is not null
      and next_action is not null
      and next_action_due_at is not null
    )
  );

-- -----------------------------------------------------------------------------
-- 4. Recipient classification for WA-6 disclosure authority
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_is_employee_relay_contact(
  p_contact_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.whatsapp_contacts wc
    join public.users u
      on lower(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'))
       = lower(regexp_replace(coalesce(wc.phone_number, ''), '\D', '', 'g'))
    where wc.id = p_contact_id
      and coalesce(u.is_active, true)
      and u.deleted_at is null
      and (
        public.is_internal_staff(u.id)
        or upper(coalesce(u.role, '')) in (
          'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
          'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
          'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
          'STORE_INCHARGE', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD', 'SECURITY_CONTROL',
          'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
        )
      )
  );
$$;

create or replace function public.whatsapp_core_c_classify_outbound_recipient_v1(
  p_contact_id uuid,
  p_potential_order_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_company_id uuid;
  v_scopes text[];
begin
  if public.whatsapp_core_c_is_employee_relay_contact(p_contact_id) then
    return jsonb_build_object(
      'recipient_class', 'EMPLOYEE_RELAY',
      'company_id', null,
      'authorized_disclosure_scope', '[]'::jsonb
    );
  end if;

  if p_potential_order_id is not null then
    select case
      when r.resolution_state in ('resolved', 'operator_confirmed')
        and r.resolved_value->>'company_id' ~ '^[0-9a-fA-F-]{36}$'
        then (r.resolved_value->>'company_id')::uuid
    end
    into v_company_id
    from public.whatsapp_order_field_resolutions r
    where r.potential_order_id = p_potential_order_id
      and r.field_key = 'client_identity';

    if v_company_id is not null then
      select coalesce(array_agg(distinct scope order by scope), '{}'::text[])
      into v_scopes
      from public.whatsapp_sender_commercial_authorizations a,
           unnest(a.disclosure_scope) scope
      where a.contact_id = p_contact_id
        and a.company_id = v_company_id
        and a.status = 'ACTIVE'
        and a.valid_until > statement_timestamp();

      if coalesce(cardinality(v_scopes), 0) > 0 then
        return jsonb_build_object(
          'recipient_class', 'VERIFIED_COMMERCIAL_CUSTOMER',
          'company_id', v_company_id,
          'authorized_disclosure_scope', to_jsonb(v_scopes)
        );
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'recipient_class', 'UNKNOWN_EXTERNAL',
    'company_id', null,
    'authorized_disclosure_scope', '[]'::jsonb
  );
end;
$$;

create or replace function public.whatsapp_core_c_resolve_promoted_ack_payload(
  p_contact_id uuid,
  p_potential_order_id uuid,
  p_order_number text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_class jsonb;
  v_recipient_class text;
  v_scopes text[];
  v_order_number text := nullif(btrim(p_order_number), '');
  v_body text;
  v_disclosure text[] := '{}'::text[];
begin
  v_class := public.whatsapp_core_c_classify_outbound_recipient_v1(p_contact_id, p_potential_order_id);
  v_recipient_class := upper(btrim(v_class->>'recipient_class'));
  select coalesce(array_agg(value), '{}'::text[])
  into v_scopes
  from jsonb_array_elements_text(coalesce(v_class->'authorized_disclosure_scope', '[]'::jsonb)) value;

  if v_recipient_class = 'VERIFIED_COMMERCIAL_CUSTOMER'
     and v_order_number is not null
     and 'sales_order' = any(v_scopes) then
    v_body := public.whatsapp_build_promoted_order_ack_message(v_order_number);
    v_disclosure := array['sales_order']::text[];
  else
    v_body := public.whatsapp_build_promoted_order_ack_message(null);
    v_disclosure := '{}'::text[];
  end if;

  return jsonb_build_object(
    'recipient_class', v_recipient_class,
    'message_body', v_body,
    'disclosure_scope', to_jsonb(v_disclosure),
    'order_reference_included', v_order_number is not null and v_disclosure = array['sales_order']::text[]
  );
end;
$$;

-- Restore full WA-6 authority (no blanket CORE-C bypass).
create or replace function public.wa6_guard_operator_reply_disclosure()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_inferred text[];
  v_required text[];
  v_company_id uuid;
begin
  v_inferred := public.wa6_infer_commercial_disclosure(new.message_body);
  select array_agg(distinct scope order by scope)
  into v_required
  from unnest(coalesce(new.disclosure_scope, '{}') || coalesce(v_inferred, '{}')) scope
  where btrim(scope) <> '';
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

-- -----------------------------------------------------------------------------
-- 5. Deterministic clarification field/question (WA-3 only, fail closed)
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_derive_clarification_field(
  p_blocking_reasons text[]
)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_field text;
begin
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like 'ambiguous_customer%' or r = 'ambiguous_customer_match'
  ) then return 'CUSTOMER'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%branch%'
  ) then return 'BRANCH'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%quantity%'
  ) then return 'QUANTITY'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%unit%' or r like '%uom%' or r like '%pack%'
  ) then return 'UOM_PACK'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%product%' or r like '%sku%'
  ) then return 'PRODUCT'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%conflict%' or r like '%contradict%'
  ) then return 'CORRECTION'; end if;

  raise exception 'CORE_C_UNRESOLVED_BLOCKING_REASON' using errcode = 'P0001';
end;
$$;

create or replace function public.whatsapp_core_c_minimum_clarification_question(
  p_field_name text,
  p_ai_draft_reply text default null
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select coalesce(
    public.wa3_clarification_question(
      case upper(btrim(coalesce(p_field_name, '')))
        when 'CUSTOMER' then 'client_identity'
        when 'BRANCH' then 'delivery_address'
        when 'PRODUCT' then 'product'
        when 'QUANTITY' then 'quantity'
        when 'UOM_PACK' then 'unit_packaging'
        when 'CORRECTION' then 'quantity'
        else null
      end
    ),
    'Which exact governed fact do you need us to clarify before we can continue?'
  );
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
  v_principal uuid;
  v_identity public.whatsapp_case_identities%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_key text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();

  select * into v_case from public.whatsapp_communication_cases where id = p_case_id;
  if not found then
    raise exception 'CORE_C_CASE_REQUIRED';
  end if;

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

  v_key := 'core-c:provenance:' || v_identity.id::text;

  insert into public.whatsapp_case_recipient_authorizations(
    case_id, identity_id, disclosure_scope, may_receive_clarification,
    may_confirm_commercial_scope, verification_method, verified_by, verified_at,
    correlation_key
  ) values (
    p_case_id, v_identity.id, '{}'::text[], true, false,
    'PROVENANCE_VERIFIED', v_principal, statement_timestamp(),
    v_key
  )
  on conflict (case_id, identity_id, correlation_key) do nothing
  returning * into v_auth;

  if v_auth.id is null then
    select * into v_auth
    from public.whatsapp_case_recipient_authorizations
    where case_id = p_case_id
      and identity_id = v_identity.id
      and correlation_key = v_key;
  end if;

  return v_auth;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Governed outbound without human impersonation or WA-6 bypass
-- -----------------------------------------------------------------------------

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
  v_recipient := public.whatsapp_core_c_classify_outbound_recipient_v1(p_contact_id, p_potential_order_id);

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
    idempotency_key, created_by
  ) values (
    p_packet_id, p_contact_id, p_potential_order_id, null,
    v_phone, v_body, 'TEXT', v_scope, v_key, v_principal
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
  v_payload jsonb;
  v_body text;
  v_scope text[];
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

  select * into v_contact
  from public.whatsapp_contacts c
  join public.whatsapp_message_packets p on p.contact_id = c.id
  where p.id = v_projection.packet_id;

  v_payload := public.whatsapp_core_c_resolve_promoted_ack_payload(
    v_contact.id, v_projection.potential_order_id, p_order_number
  );
  v_body := v_payload->>'message_body';
  select coalesce(array_agg(value), '{}'::text[])
  into v_scope
  from jsonb_array_elements_text(coalesce(v_payload->'disclosure_scope', '[]'::jsonb)) value;

  v_key := 'core-c:promoted-ack:' || p_autonomy_decision_id::text;

  v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
    v_projection.packet_id, v_contact.id,
    '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
    v_body, v_key, 'PROMOTED_ORDER_ACK',
    v_projection.potential_order_id, v_projection.case_id, null, v_scope
  );

  return jsonb_build_object(
    'reply_id', v_reply.id,
    'idempotency_key', v_key,
    'recipient_class', v_payload->>'recipient_class',
    'order_reference_included', coalesce((v_payload->>'order_reference_included')::boolean, false),
    'idempotent_replay', exists (
      select 1 from public.whatsapp_operator_reply_events e
      where e.reply_id = v_reply.id
        and e.event_type = 'CORE_C_ENQUEUED_OR_REPLAYED'
        and e.created_at < statement_timestamp() - interval '1 millisecond'
    )
  );
end;
$$;

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
  v_principal uuid;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();

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

  if v_case.case_type <> 'ORDER' then
    return jsonb_build_object(
      'case_id', v_case.id,
      'skipped', true,
      'reason', 'CORE_C_CLARIFICATION_ORDER_PATH_ONLY'
    );
  end if;

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
  v_question := public.whatsapp_core_c_minimum_clarification_question(v_field);

  insert into public.whatsapp_case_clarifications(
    case_id, field_name, question, recipient_authorization_id, status,
    due_at, next_follow_up_at, asked_by, correlation_key
  ) values (
    v_case.id, v_field, v_question, v_auth.id, 'OPEN',
    statement_timestamp() + interval '1 day',
    statement_timestamp() + interval '1 day',
    v_principal,
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
      'question', v_question,
      'verification_method', v_auth.verification_method
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

create or replace function public.whatsapp_core_c_resolve_correlated_clarification_v1(
  p_answer_evidence_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_principal uuid;
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

  v_principal := public.whatsapp_core_c_ensure_system_principal();

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
        'correlation_method', v_evidence.correlation_method,
        'confirmed_by_actor_type', 'SYSTEM'
      ),
      answer_source_message_id = v_message.id,
      answered_by_identity_id = v_auth.identity_id,
      confirmed_by = v_principal,
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
      'remaining_open_clarifications', v_remaining,
      'system_principal_id', v_principal
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
  v_principal uuid;
  v_team text;
  v_due timestamptz;
  v_key text;
  v_body text;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_allow_receipt boolean := false;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' and pg_trigger_depth() = 0 then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();

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
      accountability_status = 'UNASSIGNED',
      accountable_owner_id = null,
      assigned_at = null,
      assigned_by = null,
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
    v_principal
  )
  on conflict (case_id, correlation_key) do nothing;

  v_allow_receipt := v_case.case_type in (
    'ENQUIRY', 'COMPLAINT', 'PAYMENT_ADVICE', 'ACCOUNT_QUERY',
    'DISPATCH', 'SPECIFICATION', 'UNCLASSIFIED'
  );

  if v_allow_receipt then
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
    p_case_id, 'NON_ORDER_TEAM_ROUTED', 'SYSTEM',
    'core-c-non-order-governance:' || p_interpretation_id::text,
    jsonb_build_object(
      'accountable_team', v_team,
      'accountability_status', 'UNASSIGNED',
      'case_type', v_case.case_type,
      'intent', upper(btrim(p_intent))
    ),
    jsonb_build_object('due_at', v_due, 'interpretation_id', p_interpretation_id)
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', p_case_id,
    'accountable_team', v_team,
    'accountability_status', 'UNASSIGNED',
    'next_action_due_at', v_due,
    'receipt_sent', v_reply.id is not null
  );
end;
$$;

revoke all on function public.whatsapp_core_c_is_employee_relay_contact(uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_is_employee_relay_contact(uuid) to service_role;

revoke all on function public.whatsapp_core_c_classify_outbound_recipient_v1(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_classify_outbound_recipient_v1(uuid, uuid) to service_role;

revoke all on function public.whatsapp_core_c_resolve_promoted_ack_payload(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_resolve_promoted_ack_payload(uuid, uuid, text) to service_role;

commit;
