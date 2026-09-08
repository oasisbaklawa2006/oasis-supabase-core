-- Contract for 20260908010000_macro_trace_identity_handover_authority.sql
begin;
select plan(23);

select has_table('public', 'ols_trace_identity_sequences');
select has_table('public', 'ols_trace_handover_signing_keys');

select has_function('public', 'trace_allocate_identity_v1', array['text']);
select has_function('public', 'trace_sign_handover_evidence_v1', array['text','text','text','text','jsonb','uuid','text']);
select has_function('public', 'trace_verify_handover_evidence_v1', array['jsonb','text']);
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
select is_empty($$
  select 1
  from information_schema.role_table_grants
  where table_schema='public'
    and table_name in ('ols_trace_identity_sequences','ols_trace_handover_signing_keys')
    and grantee in ('PUBLIC','anon','authenticated')
$$, 'client roles cannot read or mutate Trace authority internals');

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
  where oid='public.trace_verify_handover_evidence_v1(jsonb,text)'::regprocedure
    and prosecdef
    and pg_get_functiondef(oid) like '%extensions.hmac%'
    and pg_get_functiondef(oid) like '%_core_key_version%'
$$, 'handover verification recomputes the backend signature with key version binding');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.trace_insert_handover_audit_v1(text,text,uuid,jsonb,text)'::regprocedure
    and pg_get_functiondef(oid) like '%trace_verify_handover_evidence_v1%'
    and pg_get_functiondef(oid) like '%TRACE_HANDOVER_EVIDENCE_BINDING_MISMATCH%'
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
  has_function_privilege('authenticated', 'public.trace_verify_handover_evidence_v1(jsonb,text)', 'EXECUTE'),
  'authenticated internal users can verify server-authenticated evidence'
);
select is_empty($$
  select 1
  from information_schema.role_routine_grants
  where routine_schema='public'
    and grantee in ('PUBLIC','anon')
    and routine_name in (
      'trace_allocate_identity_v1',
      'trace_sign_handover_evidence_v1',
      'trace_verify_handover_evidence_v1',
      'trace_insert_handover_audit_v1'
    )
$$, 'anonymous roles cannot execute new Trace authority functions');

select * from finish();
rollback;
