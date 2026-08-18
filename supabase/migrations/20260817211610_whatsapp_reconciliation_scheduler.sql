-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010900_whatsapp_reconciliation_scheduler.sql (head 3b013b4); full diff performed -- identical cron/function logic.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Run zero-loss reconciliation hourly without embedding a service-role or anon token in cron.job.
-- The wrapper is postgres-only, impersonates only the narrow internal SYSTEM detector for the
-- duration of the transaction, and cannot resolve exceptions or sign a run off.

create or replace function public.whatsapp_run_scheduled_reconciliation()
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_end timestamptz:=statement_timestamp();
  v_start timestamptz:=v_end-interval '70 minutes';
  v_due timestamptz:=v_end+interval '4 hours';
  v_key text:='cron:'||to_char(date_trunc('hour',v_end at time zone 'UTC'),'YYYYMMDDHH24');
  v_prior_claims text:=current_setting('request.jwt.claims',true);
  v_result jsonb;
begin
  -- This function is not executable by public/anon/authenticated/service_role. pg_cron executes
  -- it as the database owner. The local claims context is restored before returning.
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  v_result:=public.whatsapp_run_system_reconciliation(v_start,v_end,'SYSTEM_ROLLING',v_due,v_key);
  perform set_config('request.jwt.claims',coalesce(v_prior_claims,''),true);
  return v_result;
exception when others then
  perform set_config('request.jwt.claims',coalesce(v_prior_claims,''),true);
  raise;
end;
$$;

revoke all on function public.whatsapp_run_scheduled_reconciliation() from public,anon,authenticated,service_role;

DO $$
declare
  v_jobid bigint;
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    select jobid into v_jobid from cron.job where jobname='whatsapp-zero-loss-hourly' limit 1;
    if v_jobid is not null then perform cron.unschedule(v_jobid); end if;
    perform cron.schedule(
      'whatsapp-zero-loss-hourly',
      '7 * * * *',
      'select public.whatsapp_run_scheduled_reconciliation();'
    );
  end if;
end $$;
