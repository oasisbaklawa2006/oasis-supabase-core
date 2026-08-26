-- KNOWLEDGE-BRIDGE-A: governed AI Studio → Core DRAFT snapshot submission and
-- lifecycle transitions (DRAFT → REVIEWED → APPROVED). Activation remains the
-- existing service-role-only whatsapp_activate_intelligence_knowledge_snapshot.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- Submission registry: idempotent exact replay + conflicting replay detection.
-- ---------------------------------------------------------------------------
create table if not exists public.whatsapp_intelligence_knowledge_submissions (
  content_checksum text primary key check (length(btrim(content_checksum)) = 64),
  snapshot_id uuid not null references public.whatsapp_intelligence_knowledge_snapshots(id) on delete restrict,
  idempotency_key text unique,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp()
);

comment on table public.whatsapp_intelligence_knowledge_submissions is
  'Append-only submission registry for governed intelligence knowledge DRAFT handoffs. Enables idempotent exact replay and conflicting replay rejection.';

create index if not exists whatsapp_intelligence_knowledge_submissions_snapshot
  on public.whatsapp_intelligence_knowledge_submissions (snapshot_id);

alter table public.whatsapp_intelligence_knowledge_submissions enable row level security;
revoke all on table public.whatsapp_intelligence_knowledge_submissions from public, anon, authenticated;
grant select on table public.whatsapp_intelligence_knowledge_submissions to service_role;
revoke insert, update, delete on table public.whatsapp_intelligence_knowledge_submissions from service_role;

-- ---------------------------------------------------------------------------
-- Canonical compact JSON + checksum (matches AI Studio wa-knowledge/v1 rules).
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_jsonb_compact_text(p_value jsonb)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_kind text;
  v_key text;
  v_elem jsonb;
  v_parts text[] := '{}';
begin
  if p_value is null or p_value = 'null'::jsonb then
    return 'null';
  end if;

  v_kind := jsonb_typeof(p_value);
  if v_kind = 'string' then
    return to_jsonb(p_value #>> '{}')::text;
  elsif v_kind in ('number', 'boolean') then
    if v_kind = 'number' then
      return trim_scale((p_value #>> '{}')::numeric)::text;
    end if;
    return p_value::text;
  elsif v_kind = 'array' then
    for v_elem in select value from jsonb_array_elements(p_value) as t(value)
    loop
      v_parts := array_append(v_parts, public.whatsapp_jsonb_compact_text(v_elem));
    end loop;
    return '[' || coalesce(array_to_string(v_parts, ','), '') || ']';
  elsif v_kind = 'object' then
    for v_key in select jsonb_object_keys(p_value) order by 1
    loop
      v_parts := array_append(
        v_parts,
        to_jsonb(v_key)::text || ':' || public.whatsapp_jsonb_compact_text(p_value -> v_key)
      );
    end loop;
    return '{' || coalesce(array_to_string(v_parts, ','), '') || '}';
  end if;

  raise exception 'unsupported json kind for compact serialization: %', v_kind using errcode = '22023';
end;
$$;

revoke all on function public.whatsapp_jsonb_compact_text(jsonb) from public, anon, authenticated, service_role;

create or replace function public.whatsapp_knowledge_canonical_payload(p_knowledge jsonb)
returns jsonb
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_terms jsonb := '{}'::jsonb;
  v_aliases jsonb := '{}'::jsonb;
  v_sku_map jsonb := '{}'::jsonb;
  v_packaging jsonb := '{}'::jsonb;
  v_ambiguous jsonb := '[]'::jsonb;
  v_source_ids jsonb := '[]'::jsonb;
  v_key text;
begin
  if jsonb_typeof(p_knowledge) is distinct from 'object' then
    raise exception 'knowledge must be a JSON object' using errcode = '22023';
  end if;

  for v_key in
    select jsonb_object_keys(coalesce(p_knowledge -> 'terminology', '{}'::jsonb)) order by 1
  loop
    v_terms := v_terms || jsonb_build_object(v_key, p_knowledge -> 'terminology' -> v_key);
  end loop;
  for v_key in
    select jsonb_object_keys(coalesce(p_knowledge -> 'aliases', '{}'::jsonb)) order by 1
  loop
    v_aliases := v_aliases || jsonb_build_object(v_key, p_knowledge -> 'aliases' -> v_key);
  end loop;
  for v_key in
    select jsonb_object_keys(coalesce(p_knowledge -> 'sku_map', '{}'::jsonb)) order by 1
  loop
    v_sku_map := v_sku_map || jsonb_build_object(v_key, p_knowledge -> 'sku_map' -> v_key);
  end loop;
  for v_key in
    select jsonb_object_keys(coalesce(p_knowledge -> 'packaging', '{}'::jsonb)) order by 1
  loop
    v_packaging := v_packaging || jsonb_build_object(v_key, p_knowledge -> 'packaging' -> v_key);
  end loop;

  select coalesce(jsonb_agg(to_jsonb(value) order by value #>> '{}'), '[]'::jsonb)
  into v_ambiguous
  from jsonb_array_elements(coalesce(p_knowledge -> 'ambiguous_terms', '[]'::jsonb)) as t(value);

  select coalesce(jsonb_agg(to_jsonb(value) order by value #>> '{}'), '[]'::jsonb)
  into v_source_ids
  from jsonb_array_elements(coalesce(p_knowledge -> 'source_catalogue_version_ids', '[]'::jsonb)) as t(value);

  return jsonb_build_object(
    'schema_version', p_knowledge ->> 'schema_version',
    'terminology', v_terms,
    'aliases', v_aliases,
    'sku_map', v_sku_map,
    'packaging', v_packaging,
    'ambiguous_terms', v_ambiguous,
    'source_catalogue_version_ids', v_source_ids
  );
end;
$$;

revoke all on function public.whatsapp_knowledge_canonical_payload(jsonb) from public, anon, authenticated, service_role;

create or replace function public.whatsapp_knowledge_content_checksum(p_knowledge jsonb)
returns text
language sql
immutable
set search_path = pg_catalog, public, extensions
as $$
  select encode(
    extensions.digest(
      convert_to(public.whatsapp_jsonb_compact_text(public.whatsapp_knowledge_canonical_payload(p_knowledge)), 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function public.whatsapp_knowledge_content_checksum(jsonb) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_assert_knowledge_handoff_submitter()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_team_member(v_actor) then
    raise exception 'team member authority required for knowledge handoff submission' using errcode = '42501';
  end if;
  return v_actor;
end;
$$;

revoke all on function public.whatsapp_assert_knowledge_handoff_submitter() from public, anon, authenticated, service_role;

create or replace function public.whatsapp_assert_knowledge_review_authority()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_team_member(v_actor) then
    raise exception 'team member authority required for knowledge review' using errcode = '42501';
  end if;
  return v_actor;
end;
$$;

revoke all on function public.whatsapp_assert_knowledge_review_authority() from public, anon, authenticated, service_role;

create or replace function public.whatsapp_assert_knowledge_approval_authority()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_internal_staff(v_actor) then
    raise exception 'internal staff authority required for knowledge approval' using errcode = '42501';
  end if;
  return v_actor;
end;
$$;

revoke all on function public.whatsapp_assert_knowledge_approval_authority() from public, anon, authenticated, service_role;

create or replace function public.whatsapp_validate_knowledge_json_keys(p_value jsonb)
returns void
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_forbidden text[] := array[
    'customers', 'customer_history', 'orders', 'inbound_messages', 'whatsapp_messages',
    'conversation', 'transaction_history', 'payment', 'credit', 'sales_order',
    'whatsapp_inbound', 'customer_id', 'order_id', 'sales_order_id',
    'price_approval', 'discount_approval', 'payment_verification', 'credit_authority',
    'inventory_truth', 'stock_truth', 'delivery_promise', 'invoice_status',
    'production_status', 'so_status', 'order_status'
  ];
  v_key text;
  v_elem jsonb;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return;
  end if;

  if jsonb_typeof(p_value) = 'object' then
    for v_key in select jsonb_object_keys(p_value)
    loop
      if lower(v_key) = any(v_forbidden) then
        raise exception 'forbidden transactional knowledge field: %', v_key using errcode = '22023';
      end if;
      perform public.whatsapp_validate_knowledge_json_keys(p_value -> v_key);
    end loop;
  elsif jsonb_typeof(p_value) = 'array' then
    for v_elem in select value from jsonb_array_elements(p_value) as t(value)
    loop
      perform public.whatsapp_validate_knowledge_json_keys(v_elem);
    end loop;
  end if;
end;
$$;

revoke all on function public.whatsapp_validate_knowledge_json_keys(jsonb) from public, anon, authenticated, service_role;

create or replace function public.whatsapp_validate_knowledge_bundle(p_knowledge jsonb)
returns void
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_allowed text[] := array[
    'schema_version', 'terminology', 'aliases', 'sku_map', 'packaging',
    'ambiguous_terms', 'source_catalogue_version_ids'
  ];
  v_key text;
begin
  if jsonb_typeof(p_knowledge) is distinct from 'object' then
    raise exception 'knowledge must be a JSON object' using errcode = '22023';
  end if;

  for v_key in select jsonb_object_keys(p_knowledge)
  loop
    if not v_key = any(v_allowed) then
      raise exception 'unknown top-level knowledge field: %', v_key using errcode = '22023';
    end if;
  end loop;

  if p_knowledge ->> 'schema_version' is distinct from 'wa-knowledge/v1' then
    raise exception 'unsupported knowledge schema_version' using errcode = '22023';
  end if;
  if jsonb_typeof(p_knowledge -> 'terminology') is distinct from 'object'
     or jsonb_typeof(p_knowledge -> 'aliases') is distinct from 'object'
     or jsonb_typeof(p_knowledge -> 'sku_map') is distinct from 'object'
     or jsonb_typeof(p_knowledge -> 'packaging') is distinct from 'object'
     or jsonb_typeof(p_knowledge -> 'ambiguous_terms') is distinct from 'array'
     or jsonb_typeof(p_knowledge -> 'source_catalogue_version_ids') is distinct from 'array' then
    raise exception 'knowledge bundle shape invalid' using errcode = '22023';
  end if;

  perform public.whatsapp_validate_knowledge_json_keys(p_knowledge);
end;
$$;

revoke all on function public.whatsapp_validate_knowledge_bundle(jsonb) from public, anon, authenticated, service_role;

create or replace function public.whatsapp_validate_catalogue_version_provenance(
  p_source_catalogue_version_ids uuid[]
)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_missing uuid;
  v_invalid uuid;
begin
  if coalesce(array_length(p_source_catalogue_version_ids, 1), 0) = 0 then
    raise exception 'catalogue version provenance required' using errcode = '22023';
  end if;

  if array_position(p_source_catalogue_version_ids, null) is not null then
    raise exception 'catalogue version provenance cannot contain NULL' using errcode = '22023';
  end if;

  select version_id into v_missing
  from unnest(p_source_catalogue_version_ids) as version_id
  where not exists (
    select 1 from public.catalogue_versions cv where cv.id = version_id
  )
  limit 1;
  if v_missing is not null then
    raise exception 'unknown catalogue version: %', v_missing using errcode = '22023';
  end if;

  select version_id into v_invalid
  from unnest(p_source_catalogue_version_ids) as version_id
  join public.catalogue_versions cv on cv.id = version_id
  where cv.status not in ('approved', 'published', 'synced')
  limit 1;
  if v_invalid is not null then
    raise exception 'catalogue version not immutable: %', v_invalid using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.whatsapp_validate_catalogue_version_provenance(uuid[]) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- DRAFT submission (authenticated team member; never activates/approves).
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_submit_intelligence_knowledge_draft(
  p_schema_version text,
  p_source_catalogue_version_ids uuid[],
  p_knowledge jsonb,
  p_content_checksum text,
  p_candidate_status text,
  p_handoff_eligibility text,
  p_idempotency_key text default null
)
returns public.whatsapp_intelligence_knowledge_snapshots
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid;
  v_canonical_knowledge jsonb;
  v_computed_checksum text;
  v_knowledge_source_ids uuid[];
  v_existing public.whatsapp_intelligence_knowledge_snapshots%rowtype;
  v_registry public.whatsapp_intelligence_knowledge_submissions%rowtype;
  v_idempotency_key text := nullif(btrim(p_idempotency_key), '');
begin
  v_actor := public.whatsapp_assert_knowledge_handoff_submitter();

  if p_candidate_status is distinct from 'PUBLICATION_CANDIDATE' then
    raise exception 'only PUBLICATION_CANDIDATE may be submitted' using errcode = '22023';
  end if;
  if p_handoff_eligibility is distinct from 'HANDOFF_READY' then
    raise exception 'only HANDOFF_READY candidates may be submitted' using errcode = '22023';
  end if;
  if p_schema_version is distinct from 'wa-knowledge/v1' then
    raise exception 'unsupported schema_version' using errcode = '22023';
  end if;
  if p_content_checksum is null or length(btrim(p_content_checksum)) <> 64 then
    raise exception 'content_checksum must be a 64-char sha256 hex digest' using errcode = '22023';
  end if;

  perform public.whatsapp_validate_knowledge_bundle(p_knowledge);
  v_canonical_knowledge := public.whatsapp_knowledge_canonical_payload(p_knowledge);

  if v_idempotency_key is not null then
    select * into v_registry
    from public.whatsapp_intelligence_knowledge_submissions
    where idempotency_key = v_idempotency_key;
    if found then
      select * into v_existing
      from public.whatsapp_intelligence_knowledge_snapshots
      where id = v_registry.snapshot_id;
      if v_registry.content_checksum is distinct from lower(btrim(p_content_checksum))
         or v_existing.knowledge is distinct from v_canonical_knowledge
         or v_existing.source_catalogue_version_ids is distinct from p_source_catalogue_version_ids then
        raise exception 'idempotency key reused with conflicting payload' using errcode = '23505';
      end if;
      if v_existing.lifecycle <> 'DRAFT' then
        raise exception 'knowledge snapshot lifecycle conflict for idempotent submission: %', v_existing.lifecycle using errcode = '55000';
      end if;
      return v_existing;
    end if;
  end if;

  v_computed_checksum := public.whatsapp_knowledge_content_checksum(v_canonical_knowledge);
  if v_computed_checksum is distinct from lower(btrim(p_content_checksum)) then
    raise exception 'content_checksum does not match canonical knowledge payload' using errcode = '22023';
  end if;

  select coalesce(array_agg(value::uuid order by value::text), '{}'::uuid[])
  into v_knowledge_source_ids
  from jsonb_array_elements_text(coalesce(v_canonical_knowledge -> 'source_catalogue_version_ids', '[]'::jsonb)) as t(value);

  if v_knowledge_source_ids is distinct from (
    select coalesce(array_agg(version_id order by version_id::text), '{}'::uuid[])
    from unnest(coalesce(p_source_catalogue_version_ids, '{}'::uuid[])) as version_id
  ) then
    raise exception 'source_catalogue_version_ids mismatch between candidate and knowledge bundle' using errcode = '22023';
  end if;

  perform public.whatsapp_validate_catalogue_version_provenance(p_source_catalogue_version_ids);

  select * into v_registry
  from public.whatsapp_intelligence_knowledge_submissions
  where content_checksum = lower(btrim(p_content_checksum));
  if found then
    select * into v_existing
    from public.whatsapp_intelligence_knowledge_snapshots
    where id = v_registry.snapshot_id;
    if v_existing.knowledge is distinct from v_canonical_knowledge
       or v_existing.source_catalogue_version_ids is distinct from p_source_catalogue_version_ids then
      raise exception 'conflicting knowledge payload for existing checksum' using errcode = '23505';
    end if;
    if v_existing.lifecycle <> 'DRAFT' then
      raise exception 'knowledge snapshot lifecycle conflict for checksum replay: %', v_existing.lifecycle using errcode = '55000';
    end if;
    return v_existing;
  end if;

  insert into public.whatsapp_intelligence_knowledge_snapshots (
    schema_version,
    lifecycle,
    source_catalogue_version_ids,
    knowledge,
    content_checksum,
    created_by
  ) values (
    'wa-knowledge/v1',
    'DRAFT',
    p_source_catalogue_version_ids,
    v_canonical_knowledge,
    lower(btrim(p_content_checksum)),
    v_actor
  )
  returning * into v_existing;

  insert into public.whatsapp_intelligence_knowledge_submissions (
    content_checksum,
    snapshot_id,
    idempotency_key,
    created_by
  ) values (
    lower(btrim(p_content_checksum)),
    v_existing.id,
    v_idempotency_key,
    v_actor
  );

  return v_existing;
end;
$$;

revoke all on function public.whatsapp_submit_intelligence_knowledge_draft(
  text, uuid[], jsonb, text, text, text, text
) from public, anon;
grant execute on function public.whatsapp_submit_intelligence_knowledge_draft(
  text, uuid[], jsonb, text, text, text, text
) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- REVIEWED transition (freezes content via existing immutability trigger).
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_review_intelligence_knowledge_snapshot(
  p_snapshot_id uuid
)
returns public.whatsapp_intelligence_knowledge_snapshots
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid;
  v_row public.whatsapp_intelligence_knowledge_snapshots%rowtype;
begin
  v_actor := public.whatsapp_assert_knowledge_review_authority();

  select * into v_row
  from public.whatsapp_intelligence_knowledge_snapshots
  where id = p_snapshot_id
  for update;

  if not found then
    raise exception 'knowledge publication not found' using errcode = 'P0002';
  end if;
  if v_row.lifecycle = 'REVIEWED' and v_row.reviewed_by = v_actor then
    return v_row;
  end if;
  if v_row.lifecycle <> 'DRAFT' then
    raise exception 'only DRAFT knowledge may be reviewed' using errcode = '55000';
  end if;
  if v_row.created_by = v_actor then
    raise exception 'knowledge submitter cannot self-review' using errcode = '42501';
  end if;

  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'REVIEWED',
      reviewed_by = v_actor,
      reviewed_at = statement_timestamp()
  where id = p_snapshot_id
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.whatsapp_review_intelligence_knowledge_snapshot(uuid) from public, anon;
grant execute on function public.whatsapp_review_intelligence_knowledge_snapshot(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- APPROVED transition (no backward transitions).
-- ---------------------------------------------------------------------------
create or replace function public.whatsapp_approve_intelligence_knowledge_snapshot(
  p_snapshot_id uuid
)
returns public.whatsapp_intelligence_knowledge_snapshots
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid;
  v_row public.whatsapp_intelligence_knowledge_snapshots%rowtype;
begin
  v_actor := public.whatsapp_assert_knowledge_approval_authority();

  select * into v_row
  from public.whatsapp_intelligence_knowledge_snapshots
  where id = p_snapshot_id
  for update;

  if not found then
    raise exception 'knowledge publication not found' using errcode = 'P0002';
  end if;
  if v_row.lifecycle = 'APPROVED' and v_row.approved_by = v_actor then
    return v_row;
  end if;
  if v_row.lifecycle <> 'REVIEWED' then
    raise exception 'only REVIEWED knowledge may be approved' using errcode = '55000';
  end if;

  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'APPROVED',
      approved_by = v_actor,
      approved_at = statement_timestamp()
  where id = p_snapshot_id
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.whatsapp_approve_intelligence_knowledge_snapshot(uuid) from public, anon;
grant execute on function public.whatsapp_approve_intelligence_knowledge_snapshot(uuid) to authenticated, service_role;

comment on function public.whatsapp_submit_intelligence_knowledge_draft(
  text, uuid[], jsonb, text, text, text, text
) is 'Governed authenticated handoff from AI Studio HANDOFF_READY publication candidates. Creates DRAFT only; derives created_by from auth.uid(); validates checksum and catalogue provenance; idempotent on exact replay.';

comment on function public.whatsapp_review_intelligence_knowledge_snapshot(uuid) is
  'Governed DRAFT → REVIEWED transition. Content becomes immutable after review begins.';

comment on function public.whatsapp_approve_intelligence_knowledge_snapshot(uuid) is
  'Governed REVIEWED → APPROVED transition. Activation remains service-role-only via whatsapp_activate_intelligence_knowledge_snapshot.';

commit;
