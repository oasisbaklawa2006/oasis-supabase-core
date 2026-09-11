-- Contract assertions for migration 20260911153000_financial_ledger_edge_authority.sql
begin;

select plan(1);

do $$
declare
  required_column text;
begin
  foreach required_column in array array[
    'ledger_kind','delivery_status','delivery_attempt_count','delivery_lease_until','last_delivery_error'
  ] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'bi_monthly_ledgers' and column_name = required_column
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
  if has_function_privilege('anon', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE') then
    raise exception 'browser role can verify financial ledger cron secret';
  end if;
  if not has_function_privilege('service_role', 'public.verify_financial_ledger_cron_secret(text)', 'EXECUTE') then
    raise exception 'service_role cannot verify financial ledger cron secret';
  end if;
  if has_function_privilege('anon', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE') then
    raise exception 'browser role can invoke financial ledger operator authority';
  end if;
  if not has_function_privilege('service_role', 'public.is_financial_ledger_operator(uuid)', 'EXECUTE') then
    raise exception 'service_role cannot invoke financial ledger operator authority';
  end if;
  if has_function_privilege('anon', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE') then
    raise exception 'browser role can claim financial ledger delivery';
  end if;
  if not has_function_privilege('service_role', 'public.claim_bi_monthly_ledger_delivery(uuid,integer)', 'EXECUTE') then
    raise exception 'service_role cannot claim financial ledger delivery';
  end if;
end $$;

do $$
declare
  idxdef text;
begin
  select pg_get_indexdef(indexrelid) into idxdef
  from pg_index
  where indexrelid = 'public.uq_bi_monthly_ledgers_company_period_kind'::regclass;
  if idxdef is null
     or idxdef not like 'CREATE UNIQUE INDEX%ON public.bi_monthly_ledgers USING btree (company_id, period_start, period_end, ledger_kind)%' then
    raise exception 'financial ledger uniqueness index contract mismatch: %', coalesce(idxdef, '<missing>');
  end if;
end $$;

do $$
declare
  v_company uuid := '98000000-0000-4000-8000-000000000001';
  v_ledger uuid := '98000000-0000-4000-8000-000000000002';
  first_claim boolean;
  second_claim boolean;
  failed_retry boolean;
  stale_sending_claim boolean;
begin
  insert into public.companies (id, business_name, status)
  values (v_company, 'Financial Ledger Contract Co', 'active')
  on conflict (id) do nothing;

  insert into public.bi_monthly_ledgers (
    id, company_id, period_start, period_end, total_amount, order_count, status,
    ledger_kind, delivery_status, delivery_attempt_count
  ) values (
    v_ledger, v_company, current_date - 14, current_date, 1000, 1, 'generated',
    'bi_monthly', 'pending', 0
  );

  first_claim := public.claim_bi_monthly_ledger_delivery(v_ledger, 120);
  second_claim := public.claim_bi_monthly_ledger_delivery(v_ledger, 120);
  if first_claim is not true or second_claim is not false then
    raise exception 'delivery claim is not single-winner';
  end if;

  update public.bi_monthly_ledgers
  set delivery_status = 'failed', delivery_lease_until = null
  where id = v_ledger;
  failed_retry := public.claim_bi_monthly_ledger_delivery(v_ledger, 120);
  if failed_retry is not true then
    raise exception 'explicit failed delivery is not retryable';
  end if;

  update public.bi_monthly_ledgers
  set delivery_status = 'sending', delivery_lease_until = now() - interval '1 minute'
  where id = v_ledger;
  stale_sending_claim := public.claim_bi_monthly_ledger_delivery(v_ledger, 120);
  if stale_sending_claim is not false then
    raise exception 'ambiguous stale sending delivery was automatically re-claimed';
  end if;
end $$;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'financial_ledger_cron_v1') then
    raise exception 'financial_ledger_cron_v1 Vault secret missing';
  end if;
end $$;

select ok(true, '20260911153000 financial ledger Edge authority contract holds');
select * from finish();
rollback;