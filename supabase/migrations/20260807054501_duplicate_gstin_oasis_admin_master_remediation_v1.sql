-- Production data remediation (append-only, pre-Tranche-A):
-- Oasis Admin Master (41e34133-262c-4b7c-905f-ec26a30bd411) incorrectly shares
-- the valid normalized GSTIN 07AAFCT0640R1ZZ with canonical Oasis Baklawa
-- (dc5285b8-dbf5-46d6-b3cb-f3623571a8f0), blocking
-- uq_companies_gst_number_normalized in 20260807060000.
--
-- Remediation path A (approved): clear ONLY Admin Master gst_number.
-- No merge, delete, or reference repointing.
--
-- Non-FK company-id columns (no FK to public.companies) are explicitly scanned
-- because they can still hold operational references:
--   dispatches.company_id, documents.company_id,
--   customer_import_company_candidates.matched_company_id,
--   customer_import_contact_candidates.matched_company_id,
--   shadow_clients.promoted_to_company_id
-- org_branches / org_memberships reference org_companies, not public.companies.

create or replace function public.remediate_oasis_admin_master_duplicate_gstin_v1()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_canonical_id constant uuid := 'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0';
  v_duplicate_id constant uuid := '41e34133-262c-4b7c-905f-ec26a30bd411';
  v_gstin constant text := '07AAFCT0640R1ZZ';
  v_gstin_norm constant text := upper(regexp_replace('07AAFCT0640R1ZZ', '\s', '', 'g'));
  v_canonical_exists boolean;
  v_duplicate_exists boolean;
  v_canonical_ok boolean;
  v_duplicate_ok boolean;
  v_ref_count bigint;
  v_updated integer;
  v_fk record;
  v_non_fk_sql text;
  v_non_fk_checks constant text[] := array[
    'select count(*)::bigint from public.dispatches where company_id = $1',
    'select count(*)::bigint from public.documents where company_id = $1',
    'select count(*)::bigint from public.customer_import_company_candidates where matched_company_id = $1',
    'select count(*)::bigint from public.customer_import_contact_candidates where matched_company_id = $1',
    'select count(*)::bigint from public.shadow_clients where promoted_to_company_id = $1'
  ];
begin
  select exists(select 1 from public.companies where id = v_canonical_id) into v_canonical_exists;
  select exists(select 1 from public.companies where id = v_duplicate_id) into v_duplicate_exists;

  select exists(
    select 1
    from public.companies c
    where c.id = v_canonical_id
      and c.business_name = 'Oasis Baklawa'
      and c.status = 'active'
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_gstin_norm
  ) into v_canonical_ok;

  select exists(
    select 1
    from public.companies c
    where c.id = v_duplicate_id
      and c.business_name = 'Oasis Admin Master'
      and c.status = 'pending'
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_gstin_norm
  ) into v_duplicate_ok;

  if v_canonical_exists and not v_canonical_ok then
    raise exception
      'ABORT duplicate GSTIN remediation: canonical Oasis Baklawa fingerprint mismatch for id %',
      v_canonical_id;
  end if;

  if v_duplicate_exists and not v_duplicate_ok then
    raise exception
      'ABORT duplicate GSTIN remediation: Oasis Admin Master fingerprint mismatch for id %',
      v_duplicate_id;
  end if;

  if v_canonical_exists and not v_duplicate_exists then
    raise exception
      'ABORT duplicate GSTIN remediation: canonical company exists but Oasis Admin Master row is missing';
  end if;

  if v_duplicate_exists and not v_canonical_exists then
    raise exception
      'ABORT duplicate GSTIN remediation: Oasis Admin Master exists but canonical Oasis Baklawa row is missing';
  end if;

  if not v_canonical_ok or not v_duplicate_ok then
    -- Clean replay / environments without the production fingerprint rows: no-op.
    return;
  end if;

  -- Catalogue-driven FK dependency guard (all public FK constraints -> public.companies).
  for v_fk in
    select
      n.nspname as schema_name,
      c.relname as table_name,
      a.attname as column_name
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c on c.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    join pg_catalog.pg_attribute a
      on a.attrelid = c.oid
     and a.attnum = any (con.conkey)
     and not a.attisdropped
    where con.contype = 'f'
      and con.confrelid = 'public.companies'::regclass
      and n.nspname = 'public'
      and cardinality(con.conkey) = 1
  loop
  begin
    execute format(
      'select count(*)::bigint from %I.%I where %I = $1',
      v_fk.schema_name,
      v_fk.table_name,
      v_fk.column_name
    )
    into v_ref_count
    using v_duplicate_id;

    if v_ref_count > 0 then
      raise exception
        'ABORT duplicate GSTIN remediation: % referencing row(s) in %.% via FK column %',
        v_ref_count, v_fk.schema_name, v_fk.table_name, v_fk.column_name;
    end if;
  exception
    when undefined_table then
      raise exception
        'ABORT duplicate GSTIN remediation: FK dependency inspection failed (undefined table %.% for column %)',
        v_fk.schema_name, v_fk.table_name, v_fk.column_name;
    when undefined_column then
      raise exception
        'ABORT duplicate GSTIN remediation: FK dependency inspection failed (undefined column %.% %)',
        v_fk.schema_name, v_fk.table_name, v_fk.column_name;
  end;
  end loop;

  -- Explicit non-FK company-id column guard (documented operational references).
  foreach v_non_fk_sql in array v_non_fk_checks loop
  begin
    execute v_non_fk_sql into v_ref_count using v_duplicate_id;
    if v_ref_count > 0 then
      raise exception
        'ABORT duplicate GSTIN remediation: % referencing row(s) from non-FK guard %',
        v_ref_count, v_non_fk_sql;
    end if;
  exception
    when undefined_table then
      raise exception
        'ABORT duplicate GSTIN remediation: non-FK dependency inspection failed (% not found)',
        v_non_fk_sql;
    when undefined_column then
      raise exception
        'ABORT duplicate GSTIN remediation: non-FK dependency inspection failed (column missing in %)',
        v_non_fk_sql;
  end;
  end loop;

  update public.companies
  set gst_number = null
  where id = v_duplicate_id
    and business_name = 'Oasis Admin Master'
    and status = 'pending'
    and upper(regexp_replace(gst_number, '\s', '', 'g')) = v_gstin_norm;

  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception
      'ABORT duplicate GSTIN remediation: expected exactly 1 companies row updated, got %',
      v_updated;
  end if;

  if not exists (
    select 1
    from public.companies c
    where c.id = v_canonical_id
      and c.business_name = 'Oasis Baklawa'
      and c.status = 'active'
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = v_gstin_norm
  ) then
    raise exception
      'ABORT duplicate GSTIN remediation: canonical Oasis Baklawa row missing or GSTIN altered';
  end if;

  if not exists (
    select 1
    from public.companies c
    where c.id = v_duplicate_id
      and c.business_name = 'Oasis Admin Master'
      and c.status = 'pending'
      and c.gst_number is null
  ) then
    raise exception
      'ABORT duplicate GSTIN remediation: Oasis Admin Master not pending with NULL gst_number after update';
  end if;

  if exists (
    select 1
    from public.companies c
    where c.gst_number is not null
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
    group by upper(regexp_replace(c.gst_number, '\s', '', 'g'))
    having count(*) > 1
  ) then
    raise exception
      'ABORT duplicate GSTIN remediation: duplicate valid normalized GSTIN groups remain';
  end if;
end;
$$;

comment on function public.remediate_oasis_admin_master_duplicate_gstin_v1() is
  'Production remediation: clears gst_number on Oasis Admin Master when canonical fingerprints match and zero dependencies exist. Fail-closed on mismatch or references.';

revoke all on function public.remediate_oasis_admin_master_duplicate_gstin_v1() from public, anon, authenticated;
grant execute on function public.remediate_oasis_admin_master_duplicate_gstin_v1() to service_role;

do $$
begin
  perform public.remediate_oasis_admin_master_duplicate_gstin_v1();
end;
$$;
