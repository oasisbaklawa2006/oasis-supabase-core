-- Production data remediation (append-only, pre-Tranche-A):
-- Oasis Admin Master (41e34133-262c-4b7c-905f-ec26a30bd411) incorrectly shares
-- the valid normalized GSTIN 07AAFCT0640R1ZZ with canonical Oasis Baklawa
-- (dc5285b8-dbf5-46d6-b3cb-f3623571a8f0), blocking
-- uq_companies_gst_number_normalized in 20260807060000.
--
-- Forensic finding: zero FK child rows reference the Admin Master company;
-- it is an orphaned pending internal placeholder with a copied GSTIN.
-- Remediation path A: clear ONLY the duplicate row's gst_number (no merge/delete).

do $$
declare
  v_canonical_id constant uuid := 'dc5285b8-dbf5-46d6-b3cb-f3623571a8f0';
  v_duplicate_id constant uuid := '41e34133-262c-4b7c-905f-ec26a30bd411';
  v_gstin constant text := '07AAFCT0640R1ZZ';
  v_ref_count integer;
begin
  if not exists (
    select 1
    from public.companies c
    where c.id = v_canonical_id
      and c.business_name = 'Oasis Baklawa'
      and c.status = 'active'
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'))
  ) then
    raise notice 'SKIP duplicate GSTIN remediation: canonical Oasis Baklawa fingerprint not found';
    return;
  end if;

  if not exists (
    select 1
    from public.companies c
    where c.id = v_duplicate_id
      and c.business_name = 'Oasis Admin Master'
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'))
  ) then
    raise notice 'SKIP duplicate GSTIN remediation: Oasis Admin Master fingerprint not found';
    return;
  end if;

  select count(*) into v_ref_count
  from (
    select 1 from public.users where company_id = v_duplicate_id
    union all
    select 1 from public.profiles where company_id = v_duplicate_id
    union all
    select 1 from public.orders where company_id = v_duplicate_id
    union all
    select 1 from public.suggested_orders where matched_company_id = v_duplicate_id
    union all
    select 1 from public.wallet_transactions where company_id = v_duplicate_id
    union all
    select 1 from public.tickets where company_id = v_duplicate_id
    union all
    select 1 from public.support_tickets where company_id = v_duplicate_id
    union all
    select 1 from public.sales_order_drafts where company_id = v_duplicate_id
    union all
    select 1 from public.delivery_addresses where company_id = v_duplicate_id
    union all
    select 1 from public.notifications where company_id = v_duplicate_id
  ) refs;

  if v_ref_count > 0 then
    raise exception
      'ABORT duplicate GSTIN remediation: unexpected % referencing row(s) on Oasis Admin Master company %',
      v_ref_count, v_duplicate_id;
  end if;

  update public.companies
  set gst_number = null
  where id = v_duplicate_id
    and business_name = 'Oasis Admin Master'
    and upper(regexp_replace(gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'));

  if not exists (
    select 1
    from public.companies c
    where c.id = v_canonical_id
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) = upper(regexp_replace(v_gstin, '\s', '', 'g'))
  ) then
    raise exception 'ABORT duplicate GSTIN remediation: canonical Oasis Baklawa GSTIN was altered';
  end if;

  if exists (
    select 1
    from public.companies c
    where c.gst_number is not null
      and upper(regexp_replace(c.gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
    group by upper(regexp_replace(c.gst_number, '\s', '', 'g'))
    having count(*) > 1
  ) then
    raise exception 'ABORT duplicate GSTIN remediation: duplicate valid normalized GSTIN groups remain';
  end if;
end;
$$;
