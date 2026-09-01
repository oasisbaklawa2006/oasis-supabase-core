-- WA-OPERATOR-PERSIST: governed server-side operator workspace ledger for
-- packet notes, user-owned inbox views, and case-scoped corrections.
-- Additive roll-forward migration. No live WhatsApp mutation.

-- ---------------------------------------------------------------------------
-- Ledger tables
-- ---------------------------------------------------------------------------

create table public.whatsapp_operator_packet_notes (
  id uuid primary key default gen_random_uuid(),
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  actor_id uuid not null references public.users(id) on delete restrict,
  note_body text not null check (length(btrim(note_body)) between 1 and 8000),
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 160),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (packet_id, actor_id),
  unique (packet_id, idempotency_key)
);

create table public.whatsapp_operator_saved_views (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.users(id) on delete restrict,
  view_key text not null check (length(btrim(view_key)) between 1 and 120),
  view_label text not null check (length(btrim(view_label)) between 1 and 240),
  filter_config jsonb not null default '{}'::jsonb check (jsonb_typeof(filter_config) = 'object'),
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 160),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (owner_user_id, view_key),
  unique (owner_user_id, idempotency_key)
);

create table public.whatsapp_operator_case_corrections (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  correction_field text not null check (length(btrim(correction_field)) between 1 and 120),
  prior_value jsonb,
  corrected_value jsonb not null,
  correction_reason text,
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 160),
  actor_id uuid not null references public.users(id) on delete restrict,
  supersedes_correction_id uuid references public.whatsapp_operator_case_corrections(id) on delete restrict,
  superseded_by_correction_id uuid references public.whatsapp_operator_case_corrections(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default statement_timestamp(),
  unique (case_id, idempotency_key),
  check (supersedes_correction_id is null or supersedes_correction_id <> id),
  check (superseded_by_correction_id is null or superseded_by_correction_id <> id)
);

create index whatsapp_operator_case_corrections_active_idx
  on public.whatsapp_operator_case_corrections (case_id, correction_field, created_at desc)
  where is_active;

-- ---------------------------------------------------------------------------
-- RLS: read for inbox readers; writes only through governed RPCs
-- ---------------------------------------------------------------------------

alter table public.whatsapp_operator_packet_notes enable row level security;
alter table public.whatsapp_operator_saved_views enable row level security;
alter table public.whatsapp_operator_case_corrections enable row level security;

revoke all on public.whatsapp_operator_packet_notes,
  public.whatsapp_operator_saved_views,
  public.whatsapp_operator_case_corrections
from public, anon, authenticated;

grant select on public.whatsapp_operator_packet_notes,
  public.whatsapp_operator_saved_views,
  public.whatsapp_operator_case_corrections
to authenticated;

create policy wa_operator_notes_read on public.whatsapp_operator_packet_notes
  for select to authenticated
  using (public.has_whatsapp_permission('wa.intake.read'));

create policy wa_operator_views_read on public.whatsapp_operator_saved_views
  for select to authenticated
  using (
    owner_user_id = auth.uid()
    and public.has_whatsapp_permission('wa.intake.read')
  );

create policy wa_operator_corrections_read on public.whatsapp_operator_case_corrections
  for select to authenticated
  using (public.has_whatsapp_permission('wa.intake.read'));

-- Corrections are append-only; only supersession markers may be updated via RPC.

-- ---------------------------------------------------------------------------
-- Internal guards
-- ---------------------------------------------------------------------------

create or replace function public.wa_operator_assert_packet_exists(p_packet_id uuid)
returns public.whatsapp_message_packets
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_packet public.whatsapp_message_packets%rowtype;
begin
  if p_packet_id is null then
    raise exception 'WA_OPERATOR_PACKET_REQUIRED' using errcode = 'P0001';
  end if;
  select * into v_packet
  from public.whatsapp_message_packets
  where id = p_packet_id;
  if not found then
    raise exception 'WA_OPERATOR_PACKET_NOT_FOUND' using errcode = 'P0001';
  end if;
  return v_packet;
end;
$$;

create or replace function public.wa_operator_assert_case_packet(
  p_case_id uuid,
  p_packet_id uuid
)
returns public.whatsapp_communication_cases
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
begin
  if p_case_id is null or p_packet_id is null then
    raise exception 'WA_OPERATOR_CASE_PACKET_REQUIRED' using errcode = 'P0001';
  end if;
  select * into v_case
  from public.whatsapp_communication_cases
  where id = p_case_id;
  if not found then
    raise exception 'WA_OPERATOR_CASE_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_case.packet_id is distinct from p_packet_id then
    raise exception 'WA_OPERATOR_CASE_PACKET_MISMATCH' using errcode = 'P0001';
  end if;
  return v_case;
end;
$$;

create or replace function public.wa_operator_correction_append_only()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'WA_OPERATOR_APPEND_ONLY' using errcode = 'P0001';
  end if;
  if current_setting('app.wa_operator_governed_mutation', true) is distinct from 'on' then
    raise exception 'WA_OPERATOR_GOVERNED_MUTATION_REQUIRED' using errcode = 'P0001';
  end if;
  if old.case_id is distinct from new.case_id
    or old.packet_id is distinct from new.packet_id
    or old.correction_field is distinct from new.correction_field
    or old.prior_value is distinct from new.prior_value
    or old.corrected_value is distinct from new.corrected_value
    or old.correction_reason is distinct from new.correction_reason
    or old.idempotency_key is distinct from new.idempotency_key
    or old.actor_id is distinct from new.actor_id
    or old.supersedes_correction_id is distinct from new.supersedes_correction_id
    or old.created_at is distinct from new.created_at then
    raise exception 'WA_OPERATOR_CORRECTION_IMMUTABLE' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger wa_operator_corrections_append_only
  before update or delete on public.whatsapp_operator_case_corrections
  for each row execute function public.wa_operator_correction_append_only();

revoke all on function public.wa_operator_assert_packet_exists(uuid),
  public.wa_operator_assert_case_packet(uuid, uuid),
  public.wa_operator_correction_append_only()
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Governed RPC surface
-- ---------------------------------------------------------------------------

create or replace function public.upsert_whatsapp_operator_note(
  p_packet_id uuid,
  p_note_body text,
  p_idempotency_key text
)
returns public.whatsapp_operator_packet_notes
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_packet public.whatsapp_message_packets%rowtype;
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_body text := btrim(coalesce(p_note_body, ''));
  v_existing public.whatsapp_operator_packet_notes%rowtype;
  v_result public.whatsapp_operator_packet_notes%rowtype;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WA_OPERATOR_TRIAGE_REQUIRED' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'WA_OPERATOR_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  if v_body = '' or length(v_body) > 8000 then
    raise exception 'WA_OPERATOR_NOTE_BODY_REQUIRED' using errcode = 'P0001';
  end if;

  v_packet := public.wa_operator_assert_packet_exists(p_packet_id);

  select * into v_existing
  from public.whatsapp_operator_packet_notes
  where packet_id = v_packet.id
    and idempotency_key = v_key;
  if found then
    return v_existing;
  end if;

  insert into public.whatsapp_operator_packet_notes (
    packet_id, actor_id, note_body, idempotency_key
  ) values (
    v_packet.id, v_actor, v_body, v_key
  )
  on conflict (packet_id, actor_id) do update
  set note_body = excluded.note_body,
      idempotency_key = excluded.idempotency_key,
      updated_at = statement_timestamp()
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function public.save_whatsapp_operator_view(
  p_view_key text,
  p_view_label text,
  p_filter_config jsonb,
  p_idempotency_key text
)
returns public.whatsapp_operator_saved_views
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_view_key, ''));
  v_label text := btrim(coalesce(p_view_label, ''));
  v_idem text := btrim(coalesce(p_idempotency_key, ''));
  v_config jsonb := coalesce(p_filter_config, '{}'::jsonb);
  v_existing public.whatsapp_operator_saved_views%rowtype;
  v_result public.whatsapp_operator_saved_views%rowtype;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WA_OPERATOR_TRIAGE_REQUIRED' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 120 then
    raise exception 'WA_OPERATOR_VIEW_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  if v_label = '' or length(v_label) > 240 then
    raise exception 'WA_OPERATOR_VIEW_LABEL_REQUIRED' using errcode = 'P0001';
  end if;
  if v_idem = '' or length(v_idem) > 160 then
    raise exception 'WA_OPERATOR_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  if jsonb_typeof(v_config) <> 'object' then
    raise exception 'WA_OPERATOR_VIEW_CONFIG_OBJECT_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_existing
  from public.whatsapp_operator_saved_views
  where owner_user_id = v_actor
    and idempotency_key = v_idem;
  if found then
    return v_existing;
  end if;

  insert into public.whatsapp_operator_saved_views (
    owner_user_id, view_key, view_label, filter_config, idempotency_key
  ) values (
    v_actor, v_key, v_label, v_config, v_idem
  )
  on conflict (owner_user_id, view_key) do update
  set view_label = excluded.view_label,
      filter_config = excluded.filter_config,
      idempotency_key = excluded.idempotency_key,
      updated_at = statement_timestamp()
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function public.record_whatsapp_operator_correction(
  p_case_id uuid,
  p_packet_id uuid,
  p_correction_field text,
  p_corrected_value jsonb,
  p_idempotency_key text,
  p_prior_value jsonb default null,
  p_correction_reason text default null
)
returns public.whatsapp_operator_case_corrections
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_field text := btrim(coalesce(p_correction_field, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_existing public.whatsapp_operator_case_corrections%rowtype;
  v_prior public.whatsapp_operator_case_corrections%rowtype;
  v_result public.whatsapp_operator_case_corrections%rowtype;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WA_OPERATOR_TRIAGE_REQUIRED' using errcode = '42501';
  end if;
  if v_field = '' or length(v_field) > 120 then
    raise exception 'WA_OPERATOR_CORRECTION_FIELD_REQUIRED' using errcode = 'P0001';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'WA_OPERATOR_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  if p_corrected_value is null then
    raise exception 'WA_OPERATOR_CORRECTED_VALUE_REQUIRED' using errcode = 'P0001';
  end if;

  v_case := public.wa_operator_assert_case_packet(p_case_id, p_packet_id);

  select * into v_existing
  from public.whatsapp_operator_case_corrections
  where case_id = v_case.id
    and idempotency_key = v_key;
  if found then
    return v_existing;
  end if;

  select * into v_prior
  from public.whatsapp_operator_case_corrections
  where case_id = v_case.id
    and correction_field = v_field
    and is_active
  order by created_at desc, id desc
  limit 1
  for update;

  insert into public.whatsapp_operator_case_corrections (
    case_id,
    packet_id,
    correction_field,
    prior_value,
    corrected_value,
    correction_reason,
    idempotency_key,
    actor_id,
    supersedes_correction_id
  ) values (
    v_case.id,
    v_case.packet_id,
    v_field,
    coalesce(p_prior_value, v_prior.corrected_value),
    p_corrected_value,
    nullif(btrim(coalesce(p_correction_reason, '')), ''),
    v_key,
    v_actor,
    v_prior.id
  )
  returning * into v_result;

  if v_prior.id is not null then
    perform set_config('app.wa_operator_governed_mutation', 'on', true);
    update public.whatsapp_operator_case_corrections
    set is_active = false,
        superseded_by_correction_id = v_result.id
    where id = v_prior.id
      and is_active;
    perform set_config('app.wa_operator_governed_mutation', 'off', true);
  end if;

  return v_result;
exception
  when others then
    perform set_config('app.wa_operator_governed_mutation', 'off', true);
    raise;
end;
$$;

comment on function public.upsert_whatsapp_operator_note(uuid, text, text) is
  'Governed upsert for packet-scoped operator notes. Requires wa.intake.triage; idempotent by packet+idempotency_key; one active note per operator per packet.';

comment on function public.save_whatsapp_operator_view(text, text, jsonb, text) is
  'Governed upsert for user-owned inbox view presets. Requires wa.intake.triage; idempotent replay; never exposes other users'' views.';

comment on function public.record_whatsapp_operator_correction(uuid, uuid, text, jsonb, text, jsonb, text) is
  'Append-only case-scoped operator corrections with supersession lineage. Requires wa.intake.triage and matching case/packet identity.';

revoke all on function public.upsert_whatsapp_operator_note(uuid, text, text),
  public.save_whatsapp_operator_view(text, text, jsonb, text),
  public.record_whatsapp_operator_correction(uuid, uuid, text, jsonb, text, jsonb, text)
from public, anon;
grant execute on function public.upsert_whatsapp_operator_note(uuid, text, text),
  public.save_whatsapp_operator_view(text, text, jsonb, text),
  public.record_whatsapp_operator_correction(uuid, uuid, text, jsonb, text, jsonb, text)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Read model: extend existing case decision snapshot for Central hydration
-- ---------------------------------------------------------------------------

create or replace function public.whatsapp_get_case_decision_snapshot(p_packet_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_ai jsonb;
  v_identities jsonb;
  v_authorizations jsonb;
  v_tasks jsonb;
  v_clarifications jsonb;
  v_escalations jsonb;
  v_outbound jsonb;
  v_milestones jsonb;
  v_closure jsonb;
  v_events jsonb;
  v_operator_notes jsonb;
  v_operator_corrections jsonb;
  v_operator_saved_views jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;

  perform public.wa_operator_assert_packet_exists(p_packet_id);

  select * into v_case
  from public.whatsapp_communication_cases
  where packet_id = p_packet_id;

  if not found then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc, x.created_at desc, x.id), '[]'::jsonb)
  into v_operator_notes
  from (
    select id, packet_id, actor_id, note_body, idempotency_key, created_at, updated_at
    from public.whatsapp_operator_packet_notes
    where packet_id = p_packet_id
  ) x;

  select '[]'::jsonb into v_operator_corrections;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc, x.view_key), '[]'::jsonb)
  into v_operator_saved_views
  from (
    select id, view_key, view_label, filter_config, idempotency_key, created_at, updated_at
    from public.whatsapp_operator_saved_views
    where owner_user_id = v_actor
  ) x;

    return jsonb_build_object(
      'packet_id', p_packet_id,
      'case', null,
      'operator_workspace', jsonb_build_object(
        'packet_notes', v_operator_notes,
        'case_corrections', v_operator_corrections,
        'saved_views', v_operator_saved_views
      )
    );
  end if;

  select to_jsonb(x) into v_ai
  from (
    select id, content_fingerprint, provider_message_ids, interpretation, model_version, created_at
    from public.whatsapp_packet_ai_interpretations
    where packet_id = p_packet_id
    order by created_at desc, id desc
    limit 1
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_identities
  from (
    select id, identity_role, party_type, party_id, display_label, phone_e164,
           resolution_status, confidence, evidence, created_at
    from public.whatsapp_case_identities
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_authorizations
  from (
    select id, identity_id, disclosure_scope, may_receive_clarification,
           may_confirm_commercial_scope, verification_method, verified_by,
           verified_at, revoked_at, correlation_key, created_at
    from public.whatsapp_case_recipient_authorizations
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_tasks
  from (
    select id, department, assigned_user_id, task_type, instructions, status,
           due_at, response_payload, completed_by, completed_at, correlation_key,
           created_by, created_at, updated_at
    from public.whatsapp_case_department_tasks
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_clarifications
  from (
    select id, field_name, question, recipient_authorization_id, status, due_at,
           next_follow_up_at, asked_by, asked_at, source_outbound_message_id,
           answer_text, answered_at, correlation_key, created_at
    from public.whatsapp_case_clarifications
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_escalations
  from (
    select id, department_task_id, escalation_level, reason, escalated_to_team,
           escalated_to_user_id, due_at, acknowledged_at, resolved_at, resolution,
           correlation_key, created_at
    from public.whatsapp_case_escalations
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_outbound
  from (
    select d.id, d.recipient_authorization_id, d.message_purpose, d.disclosure_scope,
           d.message_body, d.status, d.idempotency_key, d.created_at, d.validated_at,
           d.released_by, d.released_at, d.related_clarification_id,
           d.related_milestone_event_id,
           (
             select o.status
             from public.whatsapp_operator_reply_outbox o
             where o.packet_id = v_case.packet_id
               and o.idempotency_key = 'case:' || d.id::text
             order by o.created_at desc
             limit 1
           ) as provider_status,
           (
             select o.id
             from public.whatsapp_operator_reply_outbox o
             where o.packet_id = v_case.packet_id
               and o.idempotency_key = 'case:' || d.id::text
             order by o.created_at desc
             limit 1
           ) as wa5_reply_id
    from public.whatsapp_case_outbound_decisions d
    where d.case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at, x.id), '[]'::jsonb)
  into v_milestones
  from (
    select id, milestone_type, business_object_type, business_object_id, occurred_at,
           customer_relevance, source, source_event_key, facts
    from public.whatsapp_case_milestone_events
    where case_id = v_case.id
  ) x;

  select to_jsonb(x) into v_closure
  from (
    select id, closure_type, resolution_summary, unresolved_items, customer_notified,
           closure_outbound_decision_id, closed_by, closed_at, correlation_key
    from public.whatsapp_case_closures
    where case_id = v_case.id
    limit 1
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc, x.id desc), '[]'::jsonb)
  into v_events
  from (
    select id, event_type, actor_id, actor_type, correlation_key, prior_state,
           resulting_state, metadata, occurred_at, recorded_at
    from public.whatsapp_case_events
    where case_id = v_case.id
    order by occurred_at desc, id desc
    limit 100
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc, x.created_at desc, x.id), '[]'::jsonb)
  into v_operator_notes
  from (
    select id, packet_id, actor_id, note_body, idempotency_key, created_at, updated_at
    from public.whatsapp_operator_packet_notes
    where packet_id = p_packet_id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb)
  into v_operator_corrections
  from (
    select id, case_id, packet_id, correction_field, prior_value, corrected_value,
           correction_reason, idempotency_key, actor_id, supersedes_correction_id,
           superseded_by_correction_id, is_active, created_at
    from public.whatsapp_operator_case_corrections
    where case_id = v_case.id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc, x.view_key), '[]'::jsonb)
  into v_operator_saved_views
  from (
    select id, view_key, view_label, filter_config, idempotency_key, created_at, updated_at
    from public.whatsapp_operator_saved_views
    where owner_user_id = v_actor
  ) x;

  return jsonb_build_object(
    'packet_id', p_packet_id,
    'case', to_jsonb(v_case),
    'latest_ai', v_ai,
    'identities', v_identities,
    'recipient_authorizations', v_authorizations,
    'department_tasks', v_tasks,
    'clarifications', v_clarifications,
    'escalations', v_escalations,
    'outbound_decisions', v_outbound,
    'milestones', v_milestones,
    'closure', v_closure,
    'events', v_events,
    'operator_workspace', jsonb_build_object(
      'packet_notes', v_operator_notes,
      'case_corrections', v_operator_corrections,
      'saved_views', v_operator_saved_views
    )
  );
end;
$$;

comment on function public.whatsapp_get_case_decision_snapshot(uuid) is
  'Read-only full B2B Decision Desk snapshot including governed operator workspace state (notes, corrections, caller-owned saved views).';
