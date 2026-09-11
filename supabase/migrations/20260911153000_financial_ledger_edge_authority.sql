-- Financial ledger Edge Function authority + duplicate prevention.
-- Production incident follow-up for Core #286.
-- Safe on preview/local: this migration does not schedule outbound cron jobs.

create unique index if not exists uq_bi_monthly_ledgers_company_period_status
  on public.bi_monthly_ledgers (company_id, period_start, period_end, status);

-- Generate a project-local machine secret inside Vault. The value never appears
-- in Git or cron.job. Each environment receives its own secret on replay.
do $$
begin
  if not exists (
    select 1
    from vault.decrypted_secrets
    where name = 'financial_ledger_cron_v1'
  ) then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'financial_ledger_cron_v1',
      'Machine-only secret for governed financial ledger scheduled execution'
    );
  end if;
end
$$;

create or replace function public.verify_financial_ledger_cron_secret(_candidate text)
returns boolean
language sql
stable
security definer
set search_path = public, vault, pg_temp
as $$
  select coalesce(
    length(coalesce(_candidate, '')) >= 32
    and _candidate = (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'financial_ledger_cron_v1'
      order by created_at desc
      limit 1
    ),
    false
  );
$$;

revoke all on function public.verify_financial_ledger_cron_secret(text) from public;
revoke all on function public.verify_financial_ledger_cron_secret(text) from anon;
revoke all on function public.verify_financial_ledger_cron_secret(text) from authenticated;
grant execute on function public.verify_financial_ledger_cron_secret(text) to service_role;

create or replace function public.is_financial_ledger_operator(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    exists (
      select 1
      from public.profiles p
      where p.id = _user_id
        and lower(coalesce(p.role, '')) in (
          'finance_head',
          'finance_exec',
          'admin',
          'super_admin'
        )
        and lower(coalesce(p.status, 'active')) not in ('inactive', 'disabled', 'suspended')
    )
    or exists (
      select 1
      from public.users u
      where u.id = _user_id
        and lower(coalesce(u.role, '')) in (
          'finance_head',
          'finance_exec',
          'admin',
          'super_admin'
        )
    ),
    false
  );
$$;

revoke all on function public.is_financial_ledger_operator(uuid) from public;
revoke all on function public.is_financial_ledger_operator(uuid) from anon;
revoke all on function public.is_financial_ledger_operator(uuid) from authenticated;
grant execute on function public.is_financial_ledger_operator(uuid) to service_role;

comment on function public.verify_financial_ledger_cron_secret(text) is
  'Service-role-only verifier for the Vault-backed financial ledger scheduler secret.';

comment on function public.is_financial_ledger_operator(uuid) is
  'Service-role-only finance/admin authority check for interactive financial ledger generation.';
