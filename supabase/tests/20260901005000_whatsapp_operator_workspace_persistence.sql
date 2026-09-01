-- Contract for 20260901005000_whatsapp_operator_workspace_persistence.sql.
begin;
select plan(29);

select has_table('public', 'whatsapp_operator_packet_notes', 'packet notes ledger exists');
select has_table('public', 'whatsapp_operator_saved_views', 'saved views ledger exists');
select has_table('public', 'whatsapp_operator_case_corrections', 'case corrections ledger exists');

select has_function('public', 'upsert_whatsapp_operator_note', array['uuid', 'text', 'text']);
select has_function('public', 'save_whatsapp_operator_view', array['text', 'text', 'jsonb', 'text']);
select has_function(
  'public',
  'record_whatsapp_operator_correction',
  array['uuid', 'uuid', 'text', 'jsonb', 'text', 'jsonb', 'text']
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.whatsapp_operator_packet_notes'::regclass),
  'packet notes have RLS'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.whatsapp_operator_saved_views'::regclass),
  'saved views have RLS'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.whatsapp_operator_case_corrections'::regclass),
  'case corrections have RLS'
);

select ok(
  not has_table_privilege('anon', 'public.whatsapp_operator_packet_notes', 'select'),
  'anon cannot read packet notes'
);
select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_operator_packet_notes', 'insert'),
  'clients cannot forge packet notes'
);
select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_operator_saved_views', 'insert'),
  'clients cannot forge saved views'
);
select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_operator_case_corrections', 'insert'),
  'clients cannot forge corrections'
);

select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.whatsapp_operator_case_corrections'::regclass
      and tgname = 'wa_operator_corrections_append_only'
      and not tgisinternal
  ),
  'corrections are append-only with governed supersession'
);

select isnt_empty(
  $$select 1 from pg_constraint
    where conrelid = 'public.whatsapp_operator_packet_notes'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) like '%packet_id, actor_id%'$$,
  'one active note per operator per packet'
);
select isnt_empty(
  $$select 1 from pg_constraint
    where conrelid = 'public.whatsapp_operator_packet_notes'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) like '%packet_id, actor_id, idempotency_key%'$$,
  'packet note replay is actor-scoped and idempotent'
);
select isnt_empty(
  $$select 1 from pg_constraint
    where conrelid = 'public.whatsapp_operator_saved_views'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) like '%owner_user_id, view_key, idempotency_key%'$$,
  'saved view replay is view-key scoped and idempotent'
);
select isnt_empty(
  $$select 1 from pg_constraint
    where conrelid = 'public.whatsapp_operator_case_corrections'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) like '%case_id, actor_id, idempotency_key%'$$,
  'correction replay is actor-scoped and idempotent'
);

select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.upsert_whatsapp_operator_note(uuid,text,text)'::regprocedure
      and pg_get_functiondef(oid) like '%wa.intake.triage%'$$,
  'note writes require triage capability'
);
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.save_whatsapp_operator_view(text,text,jsonb,text)'::regprocedure
      and pg_get_functiondef(oid) like '%wa.intake.triage%'$$,
  'view writes require triage capability'
);
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.record_whatsapp_operator_correction(uuid,uuid,text,jsonb,text,jsonb,text)'::regprocedure
      and pg_get_functiondef(oid) like '%wa_operator_assert_case_packet%'
      and pg_get_functiondef(oid) like '%pg_advisory_xact_lock%'$$,
  'corrections fail closed on case/packet mismatch and serialize per field'
);
select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'whatsapp_operator_case_corrections_one_active_field'
  ),
  'only one active correction per case field is enforced'
);

select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.whatsapp_get_case_decision_snapshot(uuid)'::regprocedure
      and pg_get_functiondef(oid) like '%operator_workspace%'$$,
  'decision snapshot hydrates operator workspace'
);
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.whatsapp_get_case_decision_snapshot(uuid)'::regprocedure
      and pg_get_functiondef(oid) like '%owner_user_id = v_actor%'$$,
  'snapshot exposes only caller-owned saved views'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.upsert_whatsapp_operator_note(uuid,text,text)',
    'execute'
  ),
  'anon cannot upsert operator notes'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.save_whatsapp_operator_view(text,text,jsonb,text)',
    'execute'
  ),
  'anon cannot save operator views'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.record_whatsapp_operator_correction(uuid,uuid,text,jsonb,text,jsonb,text)',
    'execute'
  ),
  'anon cannot record corrections'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.upsert_whatsapp_operator_note(uuid,text,text)',
    'execute'
  ),
  'authenticated may call note RPC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.whatsapp_get_case_decision_snapshot(uuid)',
    'execute'
  ),
  'authenticated may hydrate decision snapshot'
);

select * from finish();
rollback;
