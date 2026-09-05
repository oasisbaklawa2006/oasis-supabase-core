-- Contract for migration 20260905120000_point68_wa2_draft_review_guard_fix.sql
begin;
select plan(8);

select has_function('public', 'wa2_guard_sales_order_draft_write', array[]::text[]);

select ok(
  position('TG_TABLE_NAME = ''sales_order_drafts''' in pg_get_functiondef(
    'public.wa2_guard_sales_order_draft_write()'::regprocedure
  )) > 0,
  'guard branches on TG_TABLE_NAME for draft rows'
);

select ok(
  position('ELSIF TG_TABLE_NAME = ''sales_order_draft_audit_log''' in pg_get_functiondef(
    'public.wa2_guard_sales_order_draft_write()'::regprocedure
  )) > 0,
  'guard uses nested audit-log branch so draft writes never read NEW.action'
);

select ok(
  position('tg_table_name=' in lower(pg_get_functiondef(
    'public.wa2_guard_sales_order_draft_write()'::regprocedure
  ))) = 0,
  'invalid tg_table_name variable reference is removed from executable guard logic'
);

select ok(
  position('security definer' in lower(pg_get_functiondef(
    'public.wa2_guard_sales_order_draft_write()'::regprocedure
  ))) > 0
  and position('set search_path' in lower(pg_get_functiondef(
    'public.wa2_guard_sales_order_draft_write()'::regprocedure
  ))) > 0,
  'trigger guard remains SECURITY DEFINER with pinned search_path'
);

select ok(
  not has_function_privilege('public', 'public.wa2_guard_sales_order_draft_write()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.wa2_guard_sales_order_draft_write()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.wa2_guard_sales_order_draft_write()', 'EXECUTE'),
  'trigger guard has no client execution path'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgname = 'wa2_sales_order_drafts_write_guard'
      and not tgisinternal
      and tgfoid = 'public.wa2_guard_sales_order_draft_write()'::regprocedure
  ),
  'draft header trigger still delegates to the repaired guard'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgname = 'wa2_sales_order_draft_audit_write_guard'
      and not tgisinternal
      and tgfoid = 'public.wa2_guard_sales_order_draft_write()'::regprocedure
  ),
  'draft audit trigger still delegates to the repaired guard'
);

select * from finish();
rollback;
