-- Contract test for 20260807054501_duplicate_gstin_oasis_admin_master_remediation_v1.sql
begin;

select plan(8);

select ok(
  exists(
    select 1 from supabase_migrations.schema_migrations
    where version = '20260807054501'
  ),
  'duplicate GSTIN remediation migration is recorded before Tranche A'
);

select ok(
  (
    select version::bigint < 20260807060000
    from supabase_migrations.schema_migrations
    where version = '20260807054501'
  ),
  'remediation migration version precedes Tranche A (20260807060000)'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'companies'
      and indexname = 'uq_companies_gst_number_normalized'
  ),
  'Tranche A normalized-GSTIN unique index exists after full replay'
);

-- Live: duplicate valid GSTIN cannot survive remediation pattern; canonical row keeps GSTIN
do $$
declare
  v_canonical uuid;
  v_duplicate uuid;
  v_gstin constant text := '37AABCU9603R1ZK';
begin
  set local session_replication_role = replica;

  execute 'drop index if exists public.uq_companies_gst_number_normalized';

  insert into public.companies (business_name, gst_number, status)
  values ('Remediation Canonical Co', v_gstin, 'active')
  returning id into v_canonical;

  insert into public.companies (business_name, gst_number, status)
  values ('Remediation Duplicate Co', v_gstin, 'pending')
  returning id into v_duplicate;

  set local session_replication_role = default;

  if (
    select count(*)
    from public.companies
    where gst_number is not null
      and upper(regexp_replace(gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'))
      and upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
  ) <> 2 then
    raise exception 'REGRESSION: expected two valid GSTIN rows before remediation';
  end if;

  begin
    execute '
      create unique index remediation_contract_dup_probe
        on public.companies (upper(regexp_replace(gst_number, ''\s'', '''', ''g'')))
        where gst_number is not null
          and upper(regexp_replace(gst_number, ''\s'', '''', ''g'')) ~ ''^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$''
    ';
    raise exception 'REGRESSION: duplicate GSTIN did not block unique index creation';
  exception
    when unique_violation then
      null;
  end;

  update public.companies
  set gst_number = null
  where id = v_duplicate;

  if (
    select gst_number
    from public.companies
    where id = v_canonical
  ) is distinct from v_gstin then
    raise exception 'REGRESSION: canonical company GSTIN was altered during remediation';
  end if;

  if (
    select count(*)
    from public.companies
    where gst_number is not null
      and upper(regexp_replace(gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'))
      and upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
  ) <> 1 then
    raise exception 'REGRESSION: duplicate valid GSTIN group survived remediation';
  end if;

  execute '
    create unique index remediation_contract_dup_probe
      on public.companies (upper(regexp_replace(gst_number, ''\s'', '''', ''g'')))
      where gst_number is not null
        and upper(regexp_replace(gst_number, ''\s'', '''', ''g'')) ~ ''^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$''
  ';

  execute 'drop index if exists public.remediation_contract_dup_probe';

  execute '
    create unique index if not exists uq_companies_gst_number_normalized
      on public.companies (upper(regexp_replace(gst_number, ''\s'', '''', ''g'')))
      where gst_number is not null
        and upper(regexp_replace(gst_number, ''\s'', '''', ''g'')) ~ ''^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$''
  ';
end $$;

select pass('duplicate valid GSTIN remediation clears duplicate only; canonical GSTIN and index creation succeed');

-- Buyer authorization not broadened: staff profile with company_id remains ineligible
do $$
declare
  v_company uuid;
  v_staff uuid := gen_random_uuid();
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status)
  values ('Remediation Staff Co', 'active')
  returning id into v_company;

  insert into auth.users (id, email) values (v_staff, 'remediation-staff@example.com');
  insert into public.users (id, email, role, company_id)
  values (v_staff, 'remediation-staff@example.com', 'ADMIN', v_company);
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_staff, v_company, 'ADMIN', true, 'approved', 'remediation-staff@example.com');

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if public.customer_buyer_eligible_company_id() is not null then
    raise exception 'SECURITY REGRESSION: staff profile became customer-buyer eligible';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('customer_buyer_eligible_company_id remains closed to staff profiles with company_id');

select ok(
  not exists(
    select 1
    from public.companies c1
    join public.companies c2
      on c1.id <> c2.id
     and c1.gst_number is not null
     and c2.gst_number is not null
     and upper(regexp_replace(c1.gst_number, '\s', '', 'g')) = upper(regexp_replace(c2.gst_number, '\s', '', 'g'))
     and upper(regexp_replace(c1.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
     and upper(regexp_replace(c2.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
  ),
  'no duplicate valid normalized GSTIN groups exist after full migration replay'
);

select ok(
  exists(
    select 1 from supabase_migrations.schema_migrations
    where version = '20260807172000'
  ),
  'Tranche D checkout migration replays after remediation and Tranche A'
);

select * from finish();
rollback;
