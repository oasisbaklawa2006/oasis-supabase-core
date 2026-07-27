-- Contract test for 20260727071520_harden_legacy_security_definer_views.sql
begin;

select plan(4);

create temporary table target_legacy_views (view_name text primary key);

insert into target_legacy_views (view_name)
values
  ('cmd_department_health'),
  ('v_customer_import_batch_summary'),
  ('v_customer_import_company_phone_slots'),
  ('v_customer_import_company_required_gaps'),
  ('v_customer_import_contact_phone_gaps'),
  ('v_customer_import_duplicate_contact_phone_in_batch'),
  ('v_customer_import_duplicate_gst_in_batch'),
  ('v_customer_import_duplicate_name_in_batch'),
  ('v_customer_import_duplicate_phone_any_in_batch'),
  ('v_customer_import_duplicate_phone_in_batch'),
  ('v_customer_import_gst_match_existing'),
  ('v_customer_import_orphan_contacts'),
  ('v_customer_import_promotion_readiness');

select is(
  (
    select count(*)::integer
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join target_legacy_views t on t.view_name = c.relname
    where n.nspname = 'public'
      and c.relkind = 'v'
      and coalesce(c.reloptions, array[]::text[]) @> array['security_invoker=true']
  ),
  13,
  'all 13 legacy views use security_invoker'
);

select is(
  (
    select count(*)::integer
    from target_legacy_views t
    where has_table_privilege('anon', format('public.%I', t.view_name), 'SELECT')
  ),
  0,
  'anon cannot select any protected legacy view'
);

select is(
  (
    select count(*)::integer
    from target_legacy_views t
    where has_table_privilege(
      'authenticated',
      format('public.%I', t.view_name),
      'SELECT'
    )
  ),
  0,
  'authenticated cannot select any protected legacy view'
);

select is(
  (
    select count(*)::integer
    from target_legacy_views t
    where has_table_privilege(
      'service_role',
      format('public.%I', t.view_name),
      'SELECT'
    )
  ),
  13,
  'service_role retains read access to all protected legacy views'
);

select * from finish();
rollback;
