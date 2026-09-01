-- WA-OPERATOR-PERSIST follow-up: governed delete semantics for user-owned
-- operator notes and saved views. Deletions are audited and idempotent.

create table public.whatsapp_operator_workspace_deletions (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.users(id) on delete restrict,
  object_kind text not null check (object_kind in ('PACKET_NOTE', 'SAVED_VIEW')),
  object_id uuid,
  packet_id uuid references public.whatsapp_message_packets(id) on delete restrict,
  view_key text,
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 160),
  created_at timestamptz not null default statement_timestamp(),
  unique (actor_id, object_kind, idempotency_key),
  check (
    (object_kind = 'PACKET_NOTE' and packet_id is not null and view_key is null)
    or (object_kind = 'SAVED_VIEW' and packet_id is null and view_key is not null)
  )
);

alter table public.whatsapp_operator_workspace_deletions enable row level security;
revoke all on public.whatsapp_operator_workspace_deletions from public, anon, authenticated;
grant select on public.whatsapp_operator_workspace_deletions to authenticated;

create policy wa_operator_workspace_deletions_read
  on public.whatsapp_operator_workspace_deletions
  for select to authenticated
  using (
    actor_id = auth.uid()
    and public.has_whatsapp_permission('wa.intake.read')
  );

create or replace function public.delete_whatsapp_operator_note(
  p_packet_id uuid,
  p_idempotency_key text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_existing_deletion uuid;
  v_note_id uuid;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WA_OPERATOR_TRIAGE_REQUIRED' using errcode = '42501';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'WA_OPERATOR_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;

  perform public.wa_operator_assert_packet_exists(p_packet_id);

  select id into v_existing_deletion
  from public.whatsapp_operator_workspace_deletions
  where actor_id = v_actor
    and object_kind = 'PACKET_NOTE'
    and idempotency_key = v_key;
  if found then
    return true;
  end if;

  delete from public.whatsapp_operator_packet_notes
  where packet_id = p_packet_id
    and actor_id = v_actor
  returning id into v_note_id;

  insert into public.whatsapp_operator_workspace_deletions (
    actor_id, object_kind, object_id, packet_id, idempotency_key
  ) values (
    v_actor, 'PACKET_NOTE', v_note_id, p_packet_id, v_key
  );

  return true;
end;
$$;

create or replace function public.delete_whatsapp_operator_view(
  p_view_key text,
  p_idempotency_key text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_view_key text := btrim(coalesce(p_view_key, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_existing_deletion uuid;
  v_view_id uuid;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WA_OPERATOR_TRIAGE_REQUIRED' using errcode = '42501';
  end if;
  if v_view_key = '' or length(v_view_key) > 120 then
    raise exception 'WA_OPERATOR_VIEW_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'WA_OPERATOR_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;

  select id into v_existing_deletion
  from public.whatsapp_operator_workspace_deletions
  where actor_id = v_actor
    and object_kind = 'SAVED_VIEW'
    and idempotency_key = v_key;
  if found then
    return true;
  end if;

  delete from public.whatsapp_operator_saved_views
  where owner_user_id = v_actor
    and view_key = v_view_key
  returning id into v_view_id;

  insert into public.whatsapp_operator_workspace_deletions (
    actor_id, object_kind, object_id, view_key, idempotency_key
  ) values (
    v_actor, 'SAVED_VIEW', v_view_id, v_view_key, v_key
  );

  return true;
end;
$$;

comment on table public.whatsapp_operator_workspace_deletions is
  'Append-only audit ledger for governed deletion of user-owned WhatsApp operator workspace state.';
comment on function public.delete_whatsapp_operator_note(uuid, text) is
  'Governed idempotent deletion of the current actor''s packet note with an append-only audit record.';
comment on function public.delete_whatsapp_operator_view(text, text) is
  'Governed idempotent deletion of the current actor''s saved inbox view with an append-only audit record.';

revoke all on function public.delete_whatsapp_operator_note(uuid, text),
  public.delete_whatsapp_operator_view(text, text)
from public, anon;
grant execute on function public.delete_whatsapp_operator_note(uuid, text),
  public.delete_whatsapp_operator_view(text, text)
to authenticated, service_role;
