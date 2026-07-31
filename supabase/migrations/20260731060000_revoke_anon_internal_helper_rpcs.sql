-- Restrict internal privileged helper functions from anonymous API callers.
-- Authenticated execution is preserved because these helpers are used by
-- application authorization and row-level-security paths.

revoke execute on function public.has_catalogue_permission(text) from public, anon;
revoke execute on function public.is_account_manager(uuid, uuid) from public, anon;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.is_catalogue_reviewer() from public, anon;
revoke execute on function public.is_team_member(uuid) from public, anon;
revoke execute on function public.is_whatsapp_inbox_reader(uuid) from public, anon;

grant execute on function public.has_catalogue_permission(text) to authenticated, service_role;
grant execute on function public.is_account_manager(uuid, uuid) to authenticated, service_role;
grant execute on function public.is_admin() to authenticated, service_role;
grant execute on function public.is_catalogue_reviewer() to authenticated, service_role;
grant execute on function public.is_team_member(uuid) to authenticated, service_role;
grant execute on function public.is_whatsapp_inbox_reader(uuid) to authenticated, service_role;
