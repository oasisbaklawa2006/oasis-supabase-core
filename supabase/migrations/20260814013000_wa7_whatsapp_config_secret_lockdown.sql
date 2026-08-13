-- WA-7 release closure: provider credentials are server-side secrets, never browser data.
-- Roll forward only. Existing values are preserved for migration compatibility but become
-- service-role-only; active Edge Functions read their provider credentials from secret env vars.

drop policy if exists "Authenticated read whatsapp_config" on public.whatsapp_config;
drop policy if exists "Admins manage whatsapp_config" on public.whatsapp_config;

revoke all on table public.whatsapp_config from public, anon, authenticated;
grant select, insert, update, delete on table public.whatsapp_config to service_role;

comment on table public.whatsapp_config is
'Legacy provider configuration retained for compatibility. Secret-bearing rows are service-role-only; browser clients must never read or mutate this table.';
