-- Contract test for the guarded production duplicate-DPL reconciliation.
begin;
select plan(7);

select ok(
  exists (
    select 1 from supabase_migrations.schema_migrations
    where version = '20260814121150'
  ),
  'duplicate-DPL reconciliation migration is recorded'
);

select ok(
  (
    select version::bigint < 20260814121200
    from supabase_migrations.schema_migrations
    where version = '20260814121150'
  ),
  'duplicate-DPL reconciliation runs before Trace Gate 3 authority closure'
);

select ok(
  not exists (
    select 1 from public.ols_dpl_cartons
    where carton_id = 'a847cf72-3c10-4eb4-b183-23e88fe3c710'
  )
  or (
    select count(*) from public.ols_dpl_cartons
    where carton_id = 'a847cf72-3c10-4eb4-b183-23e88fe3c710'
  ) = 1,
  'verified carton has at most one DPL membership after reconciliation'
);

select ok(
  not exists (
    select 1 from public.ols_dpl_documents
    where id = '1a0974b0-4138-4543-97c8-1ce163f115e0'
  )
  or (
    select status from public.ols_dpl_documents
    where id = '1a0974b0-4138-4543-97c8-1ce163f115e0'
  ) = 'cancelled',
  'superseded duplicate DPL is retained as cancelled for audit when present'
);

select ok(
  not exists (
    select 1 from public.ols_dpl_cartons
    group by carton_id
    having count(*) > 1
  ),
  'no carton belongs to multiple DPLs'
);

select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'ols_dpl_cartons_single_membership_uniq'
  ),
  'single-DPL carton uniqueness index exists after Gate 3'
);

select ok(
  not exists (
    select 1 from public.ols_dpl_documents
    where id = '7ac59281-209a-4508-a09a-b397d798683d'
  )
  or exists (
    select 1 from public.ols_audit_logs
    where action = 'trace_dpl_duplicate_membership_reconciled'
      and entity_id = '06fd4f81-0b6f-4432-ad97-26a1be80fedb'
  ),
  'duplicate membership reconciliation is auditable when the verified DPL exists'
);

select * from finish();
rollback;
