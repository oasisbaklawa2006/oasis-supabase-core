-- Contract test for 20260807054501_duplicate_gstin_oasis_admin_master_remediation_v1.sql
begin;

select plan(14);

select has_function(
  'public',
  'remediate_oasis_admin_master_duplicate_gstin_v1',
  array[]::text[],
  'remediate_oasis_admin_master_duplicate_gstin_v1 exists'
);

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

select ok(
  pg_get_functiondef('public.remediate_oasis_admin_master_duplicate_gstin_v1()'::regprocedure) like '%pg_constraint%',
  'remediation uses catalogue-driven FK discovery via pg_constraint'
);

-- Fingerprint mismatch aborts remediation
do $$
begin
  set local session_replication_role = replica;

  insert into public.companies (id, business_name, gst_number, status)
  values (
    'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0',
    'Wrong Canonical Name',
    '07AAFCT0640R1ZZ',
    'active'
  );

  insert into public.companies (id, business_name, gst_number, status)
  values (
    '41e34133-262c-4b7c-905f-ec26a30bd411',
    'Oasis Admin Master',
    '07AAFCT0640R1ZZ',
    'pending'
  );

  set local session_replication_role = default;

  begin
    perform public.remediate_oasis_admin_master_duplicate_gstin_v1();
    raise exception 'REGRESSION: remediation did not abort on canonical fingerprint mismatch';
  exception
    when others then
      if position('canonical Oasis Baklawa fingerprint mismatch' in sqlerrm) = 0 then
        raise exception 'REGRESSION: unexpected error on canonical mismatch: %', sqlerrm;
      end if;
  end;
end $$;

select pass('canonical fingerprint mismatch aborts remediation');

-- Discovered FK dependency aborts remediation
do $$
begin
  set local session_replication_role = replica;

  delete from public.companies
  where id in (
    'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0',
    '41e34133-262c-4b7c-905f-ec26a30bd411'
  );

  insert into public.companies (id, business_name, gst_number, status)
  values (
    'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0',
    'Oasis Baklawa',
    '07AAFCT0640R1ZZ',
    'active'
  );

  insert into public.companies (id, business_name, gst_number, status)
  values (
    '41e34133-262c-4b7c-905f-ec26a30bd411',
    'Oasis Admin Master',
    '07AAFCT0640R1ZZ',
    'pending'
  );

  insert into auth.users (id, email)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fk-guard-test@example.com');

  insert into public.users (id, email, role, company_id)
  values (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'fk-guard-test@example.com',
    'client',
    '41e34133-262c-4b7c-905f-ec26a30bd411'
  );

  set local session_replication_role = default;

  begin
    perform public.remediate_oasis_admin_master_duplicate_gstin_v1();
    raise exception 'REGRESSION: remediation did not abort on FK dependency';
  exception
    when others then
      if position('referencing row(s)' in sqlerrm) = 0 then
        raise exception 'REGRESSION: unexpected error on FK dependency: %', sqlerrm;
      end if;
  end;
end $$;

select pass('catalogue-discovered FK dependency aborts remediation');

-- Duplicate fingerprint mismatch aborts remediation
do $$
begin
  set local session_replication_role = replica;

  update public.companies
  set business_name = 'Oasis Baklawa',
      gst_number = '07AAFCT0640R1ZZ',
      status = 'active'
  where id = 'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0';

  update public.companies
  set business_name = 'Oasis Admin Master',
      gst_number = '07AAFCT0640R1ZZ',
      status = 'active'
  where id = '41e34133-262c-4b7c-905f-ec26a30bd411';

  set local session_replication_role = default;

  begin
    perform public.remediate_oasis_admin_master_duplicate_gstin_v1();
    raise exception 'REGRESSION: remediation did not abort on duplicate fingerprint mismatch';
  exception
    when others then
      if position('Oasis Admin Master fingerprint mismatch' in sqlerrm) = 0 then
        raise exception 'REGRESSION: unexpected error on duplicate mismatch: %', sqlerrm;
      end if;
  end;
end $$;

select pass('duplicate fingerprint mismatch aborts remediation');

-- Zero dependencies: remediation clears duplicate GSTIN only
do $$
begin
  set local session_replication_role = replica;

  delete from public.users where company_id = '41e34133-262c-4b7c-905f-ec26a30bd411';
  delete from auth.users where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

  update public.companies
  set business_name = 'Oasis Baklawa',
      gst_number = '07AAFCT0640R1ZZ',
      status = 'active'
  where id = 'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0';

  update public.companies
  set business_name = 'Oasis Admin Master',
      gst_number = '07AAFCT0640R1ZZ',
      status = 'pending'
  where id = '41e34133-262c-4b7c-905f-ec26a30bd411';

  set local session_replication_role = default;

  perform public.remediate_oasis_admin_master_duplicate_gstin_v1();

  if (
    select gst_number
    from public.companies
    where id = 'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0'
  ) is distinct from '07AAFCT0640R1ZZ' then
    raise exception 'REGRESSION: canonical Oasis Baklawa GSTIN was altered';
  end if;

  if not exists (
    select 1
    from public.companies
    where id = '41e34133-262c-4b7c-905f-ec26a30bd411'
      and business_name = 'Oasis Admin Master'
      and status = 'pending'
      and gst_number is null
  ) then
    raise exception 'REGRESSION: Oasis Admin Master not pending with NULL gst_number after remediation';
  end if;

  if exists (
    select 1
    from public.companies
    where gst_number is not null
      and upper(regexp_replace(gst_number, '\s', '', 'g')) = '07AAFCT0640R1ZZ'
      and upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
    group by upper(regexp_replace(gst_number, '\s', '', 'g'))
    having count(*) > 1
  ) then
    raise exception 'REGRESSION: duplicate valid normalized GSTIN group remains for 07AAFCT0640R1ZZ';
  end if;
end $$;

select pass('zero dependencies permit remediation; canonical untouched; Admin Master pending with NULL gst_number');

-- Generic duplicate GSTIN remediation pattern + Tranche A index creation
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

  update public.companies set gst_number = null where id = v_duplicate;

  execute '
    create unique index if not exists uq_companies_gst_number_normalized
      on public.companies (upper(regexp_replace(gst_number, ''\s'', '''', ''g'')))
      where gst_number is not null
        and upper(regexp_replace(gst_number, ''\s'', '''', ''g'')) ~ ''^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$''
  ';
end $$;

select pass('Tranche A normalized GSTIN unique index creates after duplicate GSTIN cleared');

-- Buyer authorization not broadened
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
  not has_function_privilege('authenticated', 'public.remediate_oasis_admin_master_duplicate_gstin_v1()', 'EXECUTE'),
  'authenticated cannot execute remediation function directly'
);

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
