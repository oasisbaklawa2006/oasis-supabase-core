begin;

select plan(1);

do $$
declare
  unhealthy integer;
begin
  if to_regclass('public.realtime_subscription_contracts') is null then
    raise exception 'realtime_subscription_contracts is missing';
  end if;
  if to_regclass('public.realtime_contract_health') is null then
    raise exception 'realtime_contract_health is missing';
  end if;
  select count(*) into unhealthy
  from public.realtime_contract_health
  where enabled and health_status <> 'healthy';
  if unhealthy <> 0 then
    raise exception '% enabled realtime contracts are unhealthy', unhealthy;
  end if;
  if (select count(*) from public.realtime_contract_health where enabled) <> 3 then
    raise exception 'expected exactly three approved realtime contracts';
  end if;
end $$;

select ok(true, 'Realtime subscription governance contract holds');
select * from finish();
rollback;
