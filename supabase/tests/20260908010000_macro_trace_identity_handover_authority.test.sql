-- Contract for 20260908010000_macro_trace_identity_handover_authority.sql
begin;
select plan(28);

select has_table('public', 'ols_trace_identity_sequences', 'Trace identity sequence authority exists');
select has_table('public', 'ols_trace_handover_signing_keys', 'Trace handover signing key authority exists');

select has_function('public', 'trace_allocate_identity_v1', array['text']);
select has_function('public', 'trace_sign_handover_evidence_v1', array['text','text','text','text','jsonb','uuid','text']);
select has_function('public', 'trace_verify_handover_evidence_v1', array['jsonb','text','text','boolean']);
select has_function('public', 'trace_insert_handover_audit_v1', array['text','text','uuid','jsonb','text']);
select has_function('public', 'trace_finalize_carton_v1', array['uuid','numeric','numeric','boolean','text','jsonb','uuid']);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.ols_trace_identity_sequences'::regclass),
  'identity sequence table has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.ols_trace_handover_signing_keys'::regclass),
  'handover signing key table has RLS enabled'
);
select ok(
  not has_table_privilege('anon', 'public.ols_trace_identity_sequences', 'SELECT')
  and not has_table_privilege('authenticated', 'public.ols_trace_identity_sequences', 'SELECT')
  and not has_table_privilege('anon', 'public.ols_trace_handover_signing_keys', 'SELECT')
  and not has_table_privilege('authenticated', 'public.ols_trace_handover_signing_keys', 'SELECT'),
  'client roles cannot read or mutate Trace authority internals'
);

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_allocate_identity_v1(text)'::regprocedure
    and prosecdef
    and pg_get_functiondef(oid) like '%ON CONFLICT (kind, bucket_date)%'
    and pg_get_functiondef(oid) like '%next_value = public.ols_trace_identity_sequences.next_value + 1%'
$$, 'identity allocation is an atomic server-side sequence mutation');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_create_production_v1(jsonb,jsonb,text)'::regprocedure
    and pg_get_functiondef(oid) like '%trace_allocate_identity_v1(''batch'')%'
    and pg_get_functiondef(oid) like '%trace_allocate_identity_v1(''production_label'')%'
$$, 'production creation allocates batch and label identities on Core');

select is_empty($$
  select 1 from pg_proc
  where oid='public.trace_create_production_v1(jsonb,jsonb,text)'::regprocedure
    and (
      pg_get_functiondef(oid) like '%p_input->>''batch_no''%'
      or pg_get_functiondef(oid) like '%item->>''label_no''%'
    )
$$, 'production creation no longer consumes client-selected batch or label numbers');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text)'::regprocedure
    and prosecdef
    and pg_get_functiondef(oid) like '%extensions.hmac%'
    and pg_get_functiondef(oid) like '%auth.uid()%'
    and pg_get_functiondef(oid) like '%clock_timestamp()%'
    and pg_get_functiondef(oid) like '%core_signed_v1%'
$$, 'handover signing uses backend HMAC with authenticated actor and server time');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean)'::regprocedure
    and prosecdef
    and pg_get_functiondef(oid) like '%extensions.hmac%'
    and pg_get_functiondef(oid) like '%_core_key_version%'
    and pg_get_functiondef(oid) like '%trace_handover_expected_stage_v1%'
$$, 'handover verification recomputes the backend signature with action/stage binding');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text)'::regprocedure
    and pg_get_functiondef(oid) like '%trace_verify_handover_evidence_v1%'
    and pg_get_functiondef(oid) like '%TRACE_HANDOVER_EVIDENCE_BINDING_MISMATCH%'
    and pg_get_functiondef(oid) like '%pg_advisory_xact_lock%'
$$, 'handover audit insertion verifies signature and entity/actor binding');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text,jsonb,uuid)'::regprocedure
    and pg_get_functiondef(oid) like '%trace_verify_handover_evidence_v1%'
    and pg_get_functiondef(oid) like '%trace_carton_finalized%'
    and pg_get_functiondef(oid) like '%handover_evidence%'
$$, 'authenticated carton finalisation verifies and persists handover evidence atomically');

-- Use pg_proc/acl directly for overload-specific grant assertions.
select ok(
  has_function_privilege('authenticated', 'public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text,jsonb,uuid)', 'EXECUTE'),
  'authenticated may execute only the evidence-bearing carton finaliser'
);
select ok(
  not has_function_privilege('authenticated', 'public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text)', 'EXECUTE'),
  'authenticated cannot use the legacy evidence-free carton finaliser'
);
select ok(
  has_function_privilege('authenticated', 'public.trace_allocate_identity_v1(text)', 'EXECUTE'),
  'authenticated Trace operators can call governed identity allocation'
);
select ok(
  has_function_privilege('authenticated', 'public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text)', 'EXECUTE'),
  'authenticated Trace operators can request server-authenticated handover evidence'
);
select ok(
  has_function_privilege('authenticated', 'public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean)', 'EXECUTE'),
  'authenticated internal users can verify server-authenticated evidence'
);
select ok(
  not has_function_privilege('anon', 'public.trace_allocate_identity_v1(text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.trace_allocate_identity_v1(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean)', 'EXECUTE')
  and not has_function_privilege('public', 'public.trace_verify_handover_evidence_v1(jsonb,text,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text)', 'EXECUTE'),
  'anonymous roles cannot execute new Trace authority functions'
);

insert into public.users (id, role) values
  ('a9080000-0000-0000-0000-000000000001', 'PRODUCTION'),
  ('a9080000-0000-0000-0000-000000000002', 'PACKING_SUPERVISOR');

set local request.jwt.claim.sub = 'a9080000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select matches(
  public.trace_allocate_identity_v1('batch'),
  '^BAT-[0-9]{8}-[0-9]{3}$',
  'server-allocated batch identity matches canonical format'
);

create temp table macro_trace_identity_samples (first text, second text) on commit drop;
insert into macro_trace_identity_samples (first, second)
values (
  public.trace_allocate_identity_v1('batch'),
  public.trace_allocate_identity_v1('batch')
);

select ok(
  (select split_part(second, '-', 3)::int > split_part(first, '-', 3)::int
     from macro_trace_identity_samples),
  'batch identity allocation increments monotonically within the same day bucket'
);

set local request.jwt.claim.sub = 'a9080000-0000-0000-0000-000000000002';

create temp table macro_trace_handover_evidence (signed jsonb) on commit drop;
insert into macro_trace_handover_evidence (signed)
select public.trace_sign_handover_evidence_v1(
  'packing',
  'carton',
  'a9080000-0000-0000-0000-000000000099',
  'CTN-REF-0908',
  '{}'::jsonb,
  null,
  null
);

select is(
  public.trace_verify_handover_evidence_v1(
    (select signed from macro_trace_handover_evidence),
    null,
    'trace_carton_finalized',
    true
  ),
  true,
  'signed handover evidence verifies for the bound carton finalisation action'
);

select is(
  public.trace_verify_handover_evidence_v1(
    (select signed from macro_trace_handover_evidence) || jsonb_build_object('entityId', 'tampered-entity'),
    null,
    'trace_carton_finalized',
    true
  ),
  false,
  'tampered handover evidence fails verification'
);

select is(
  public.trace_verify_handover_evidence_v1(
    (select signed from macro_trace_handover_evidence),
    null,
    'trace_production_created',
    true
  ),
  false,
  'packing-stage evidence cannot be replayed for a production audit action'
);

select * from finish();
rollback;
