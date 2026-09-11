-- Financial ledger Edge Function authority + duplicate prevention.
-- Production incident follow-up for Core #286.
-- Safe on preview/local: this migration does not schedule outbound cron jobs.

alter table public.bi_monthly_ledgers
  add column if not exists ledger_kind text not null default 'bi_monthly',
  add column if not exists delivery_status text not null default 'pending',
  add column if not exists delivery_attempt_count integer not null default 0,
  add column if not exists last_delivery_error text;

alter table public.bi_monthly_ledgers
  drop constraint if exists bi_monthly_ledgers_ledger_kind_check,
  add constraint bi_monthly_ledgers_ledger_kind_check
    check (ledger_kind in ('bi_monthly', 'rescue_reminder')),
  drop constraint if exists bi_monthly_ledgers_delivery_status_check,
  add constraint bi_monthly_ledgers_delivery_status_check
    check (delivery_status in ('pending', 'sent', 'failed', 'skipped')),
  drop constraint if exists bi_monthly_ledgers_delivery_attempt_count_check,
  add constraint bi_monthly_ledgers_delivery_attempt_count_check
    check (delivery_attempt_count >= 0);

-- Preserve compatibility with any legacy rows while separating document kind
-- from delivery outcome for all governed writes going forward.
update public.bi_monthly_ledgers
set ledger_kind = case
      when status = 'rescue_reminder' then 'rescue_reminder'
      else 'bi_monthly'
    end,
    delivery_status = case
      when whatsapp_message_id is not null or sent_at is not null then 'sent'
      else 'pending'
    end
where ledger_kind = 'bi_monthly'
  and delivery_status = 'pending';

drop index if exists public.uq_bi_monthly_ledgers_company_period_status;
create unique index if not exists uq_bi_monthly_ledgers_company_period_kind
  on public.bi_monthly_ledgers (company_id, period_start, period_end, ledger_kind);

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
        and coalesce(u.is_active, true)
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
