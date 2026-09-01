-- Contract for 20260901005800_whatsapp_operator_workspace_delete_semantics.sql.
begin;
select plan(13);

select has_table(
  'public',
  'whatsapp_operator_workspace_deletions',
  'operator workspace deletion audit ledger exists'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.whatsapp_operator_workspace_deletions'::regclass),
  'operator workspace deletion audit ledger has RLS'
);

select has_function(
  'public',
  'delete_whatsapp_operator_note',
  array['uuid','text'],
  'governed packet-note delete RPC exists'
);

select has_function(
  'public',
  'delete_whatsapp_operator_view',
  array['text','text'],
  'governed saved-view delete RPC exists'
);

select ok(
  has_function_privilege('authenticated', 'public.delete_whatsapp_operator_note(uuid,text)', 'EXECUTE'),
  'authenticated may execute packet-note delete RPC'
);

select ok(
  not has_function_privilege('anon', 'public.delete_whatsapp_operator_note(uuid,text)', 'EXECUTE'),
  'anon may not execute packet-note delete RPC'
);

select ok(
  not has_function_privilege('service_role', 'public.delete_whatsapp_operator_note(uuid,text)', 'EXECUTE'),
  'service role cannot invoke actor-scoped packet-note delete without user identity'
);

select ok(
  has_function_privilege('authenticated', 'public.delete_whatsapp_operator_view(text,text)', 'EXECUTE'),
  'authenticated may execute saved-view delete RPC'
);

select ok(
  not has_function_privilege('anon', 'public.delete_whatsapp_operator_view(text,text)', 'EXECUTE'),
  'anon may not execute saved-view delete RPC'
);

select ok(
  not has_function_privilege('service_role', 'public.delete_whatsapp_operator_view(text,text)', 'EXECUTE'),
  'service role cannot invoke actor-scoped saved-view delete without user identity'
);

select ok(
  has_table_privilege('authenticated', 'public.whatsapp_operator_workspace_deletions', 'SELECT'),
  'authenticated may read own deletion audit rows through RLS'
);

select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_operator_workspace_deletions', 'INSERT'),
  'authenticated cannot insert deletion audit rows directly'
);

select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_operator_workspace_deletions', 'DELETE'),
  'authenticated cannot delete deletion audit rows directly'
);

select * from finish();
rollback;
