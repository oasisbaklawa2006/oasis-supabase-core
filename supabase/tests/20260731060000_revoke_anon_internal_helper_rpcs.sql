-- Contract for migration 20260731060000_revoke_anon_internal_helper_rpcs
begin;

select plan(12);

select ok(
  not has_function_privilege('anon', 'public.has_catalogue_permission(text)', 'EXECUTE'),
  'anon cannot execute has_catalogue_permission(text)'
);
select ok(
  not has_function_privilege('anon', 'public.is_account_manager(uuid,uuid)', 'EXECUTE'),
  'anon cannot execute is_account_manager(uuid,uuid)'
);
select ok(
  not has_function_privilege('anon', 'public.is_admin()', 'EXECUTE'),
  'anon cannot execute is_admin()'
);
select ok(
  not has_function_privilege('anon', 'public.is_catalogue_reviewer()', 'EXECUTE'),
  'anon cannot execute is_catalogue_reviewer()'
);
select ok(
  not has_function_privilege('anon', 'public.is_team_member(uuid)', 'EXECUTE'),
  'anon cannot execute is_team_member(uuid)'
);
select ok(
  not has_function_privilege('anon', 'public.is_whatsapp_inbox_reader(uuid)', 'EXECUTE'),
  'anon cannot execute is_whatsapp_inbox_reader(uuid)'
);

select ok(
  has_function_privilege('authenticated', 'public.has_catalogue_permission(text)', 'EXECUTE'),
  'authenticated can execute has_catalogue_permission(text)'
);
select ok(
  has_function_privilege('authenticated', 'public.is_account_manager(uuid,uuid)', 'EXECUTE'),
  'authenticated can execute is_account_manager(uuid,uuid)'
);
select ok(
  has_function_privilege('authenticated', 'public.is_admin()', 'EXECUTE'),
  'authenticated can execute is_admin()'
);
select ok(
  has_function_privilege('authenticated', 'public.is_catalogue_reviewer()', 'EXECUTE'),
  'authenticated can execute is_catalogue_reviewer()'
);
select ok(
  has_function_privilege('authenticated', 'public.is_team_member(uuid)', 'EXECUTE'),
  'authenticated can execute is_team_member(uuid)'
);
select ok(
  has_function_privilege('authenticated', 'public.is_whatsapp_inbox_reader(uuid)', 'EXECUTE'),
  'authenticated can execute is_whatsapp_inbox_reader(uuid)'
);

select * from finish();
rollback;
