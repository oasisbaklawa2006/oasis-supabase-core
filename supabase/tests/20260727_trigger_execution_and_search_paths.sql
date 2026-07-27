-- Contract test for 20260727160000_harden_trigger_execution_and_search_paths.sql
begin;

select plan(4);

create temporary table target_trigger_functions (function_name text primary key);
insert into target_trigger_functions (function_name)
values
  ('activate_company_on_application_approval'),
  ('block_orders_when_frozen'),
  ('dispatch_completion_evidence_immutable'),
  ('dispatch_readiness_evidence_immutable'),
  ('dispatch_release_lineage_immutable'),
  ('enforce_sales_order_draft_immutable_fields'),
  ('finance_review_evidence_immutable'),
  ('guard_companies_is_frozen'),
  ('guard_is_frozen_changes'),
  ('handle_credit_payment'),
  ('handle_new_user'),
  ('link_buyer_on_application_approval'),
  ('notify_admin_new_b2b_application'),
  ('prevent_profile_privilege_escalation'),
  ('support_ticket_set_customer_context'),
  ('update_outstanding_on_order');

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join target_trigger_functions t on t.function_name = p.proname
    where n.nspname = 'public'
      and pg_get_function_result(p.oid) = 'trigger'
      and not has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  16,
  'anon cannot directly execute any protected trigger function'
);

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join target_trigger_functions t on t.function_name = p.proname
    where n.nspname = 'public'
      and pg_get_function_result(p.oid) = 'trigger'
      and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  16,
  'authenticated cannot directly execute any protected trigger function'
);

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'get_product_price',
        'get_product_price_usd',
        'resolve_order_qty_to_kg',
        'dispatch_readiness_evidence_immutable',
        'finance_review_evidence_immutable',
        'dispatch_completion_evidence_immutable',
        'dispatch_release_lineage_immutable',
        'catalogue_slugify_tag_part',
        'customer_import_normalize_gst',
        'customer_import_normalize_phone_last10',
        'customer_import_normalize_payment_terms',
        'enforce_sales_order_draft_immutable_fields',
        'customer_import_set_updated_at',
        'validate_sales_order_draft_readiness'
      )
      and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=%'
  ),
  14,
  'all 14 advisor-reported functions have deterministic search paths'
);

select is(
  (
    select count(distinct p.oid)::integer
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace n on n.oid = p.pronamespace
    join target_trigger_functions f on f.function_name = p.proname
    where not t.tgisinternal
      and n.nspname = 'public'
  ),
  16,
  'every protected trigger function remains bound to at least one trigger'
);

select * from finish();
rollback;
