-- Scope Stage-1B semantic normalization to the governed AI resolver policy.
-- Historical/Core-C interpretations carry their own resolver policy and must retain
-- the intent supplied by that contract so correction authority remains unchanged.

create or replace function public.whatsapp_normalize_ai_interpretation_before_insert_v2()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
begin
  if coalesce(new.resolver_policy_version, '') not in (
    '',
    'wa-resolver-policy/v1',
    'wa-resolver-policy/v2'
  ) then
    return new;
  end if;

  new.interpretation := public.normalize_whatsapp_ai_interpretation_v2(new.interpretation);
  new.resolver_policy_version := 'wa-resolver-policy/v2';
  return new;
end;
$$;

revoke all on function public.whatsapp_normalize_ai_interpretation_before_insert_v2()
  from public, anon, authenticated;
grant execute on function public.whatsapp_normalize_ai_interpretation_before_insert_v2()
  to service_role;

comment on function public.whatsapp_normalize_ai_interpretation_before_insert_v2() is
  'Applies resolver-policy/v2 semantic normalization only to governed wa-resolver-policy inputs; preserves other resolver contracts unchanged.';
