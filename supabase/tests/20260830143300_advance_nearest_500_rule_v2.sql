-- Contract for migration 20260830143300_advance_nearest_500_rule_v2.sql.

select plan(11);

select is(public.calculate_sales_order_advance_v1(10000), 3000::numeric, '30 percent exact increment');
select is(public.calculate_sales_order_advance_v1(11000), 3500::numeric, '3300 rounds to nearest 3500');
select is(public.calculate_sales_order_advance_v1(9000), 2500::numeric, '2700 rounds to nearest 2500');
select is(public.calculate_sales_order_advance_v1(501), 500::numeric, 'positive governed SO has minimum INR 500 advance');
select is(public.calculate_sales_order_advance_v1(0), 0::numeric, 'zero value requires no advance');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) like '%round((p_sales_order_value * 0.30) / 500) * 500%','canonical calculator uses nearest-500 rounding');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) like '%greatest(500%','canonical calculator enforces positive-SO minimum');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) not like '%ceil(%','upward-only rounding removed for future calculations');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%advance-30pct-nearest-inr-500/v2%','new snapshots identify rule v2');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%wa-draft:%','snapshot builder preserves canonical WhatsApp draft lineage');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%WHATSAPP_SOURCE_REFERENCE_REQUIRED%','snapshot builder remains fail-closed when WhatsApp lineage is missing');

select * from finish();
