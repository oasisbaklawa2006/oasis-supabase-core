-- Contract assertions for migration 20260911153000_financial_ledger_edge_authority.sql
begin;

select plan(1);

do $$
declare
  required_column text;
begin
  foreach required_column in array array[
    'ledger_kind',
    'delivery_status',
    'delivery_attempt_count',
    'delivery_lease_until',
    'last_delivery_error'
  ] loop
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'bi_monthly_ledgers'
        and column_name = required_column
    ) then
      raise exception 'bi_monthly_ledgers.% is missing', required_column;
    end if;
  end loop;
end $$;

do $$
begin
  if to_regprocedure('public.verify_financial_ledger_cron_secret(text)') is null then
    raise exception 'verify_financial_ledger_cron_secret(text) is missing';
  end if;
  if to_regprocedure('public.is_financial_ledger_operator(uuid)') is null then
    raise exception 'is_financial_ledger_operator(uuid) is missing';
  end if;
  if to_regprocedure('public.claim_bi_monthly_ledger_delivery(uuid,integer)') is null then
    raise exception 'claim_bi_monthly_ledger_delivery(uuid,integer) is missing';
  end if;
end $$;

do $$
begin
  if has_function_privilege('anon', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE') then
    raise exception 'anon can verify the financial ledger cron secret';
  end if;
  if has_function_privilege('authenticated', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE') then
    raise exception 'authenticated can verify the financial ledger cron secret';
  end if;
  if not has_function_privilege('service_role', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE') then
    raise exception 'service_role cannot verify the financial ledger cron secret';
  end if;

  if has_function_privilege('anon', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE') then
    raise exception 'anon can invoke financial ledger operator authority';
  end if;
  if has_function_privilege('authenticated', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE') then
    raise exception 'authenticated can invoke financial ledger operator authority directly';
  end if;
  if not has_function_privilege('service_role', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE') then
    raise exception 'service_role cannot invoke financial ledger operator authority';
  end if;

  if has_function_privilege('anon', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE') then
    raise exception 'anon can claim financial ledger delivery';
  end if;
  if has_function_privilege('authenticated', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE') then
    raise exception 'authenticated can claim financial ledger delivery directly';
  end if;
  if not has_function_privilege('service_role', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE') then
    raise exception 'service_role cannot claim financial ledger delivery';
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'bi_monthly_ledgers'
      and indexname = 'uq_bi_monthly_ledgers_company_period_kind'
  ) then
    raise exception 'financial ledger company/period/kind uniqueness index missing';
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from vault.secrets
    where name = 'financial_ledger_cron_v1'
  ) then
    raise exception 'financial_ledger_cron_v1 Vault secret missing';
  end if;
end $$;

select ok(true, '20260911153000 financial ledger Edge authority contract holds');
select * from finish();
rollback;
