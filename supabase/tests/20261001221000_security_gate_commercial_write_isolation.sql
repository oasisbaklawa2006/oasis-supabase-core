-- Contract for migration 20261001221000_security_gate_commercial_write_isolation.sql.
begin;
select plan(9);

select ok(
  position('GATE_SECURITY' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='Staff update non-governed order fields'),'')))>0
  and position('SECURITY_CONTROL' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='Staff update non-governed order fields'),'')))>0,
  'generic staff order updates explicitly exclude Security Gate roles'
);

select ok(
  position('NOT' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers insert own company orders'),'')))>0
  and position('GATE_SECURITY' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers insert own company orders'),'')))>0,
  'order insert policy cannot be reached by Security through buyer or generic staff branch'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers insert own orders'),'')))>0
  and position('NOT' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers insert own orders'),'')))>0,
  'buyer order insert excludes every internal staff identity'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers update own draft orders'),'')))>0
  and position('NOT' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='Buyers update own draft orders'),'')))>0,
  'buyer draft update excludes every internal staff identity'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='buyer_update_submitted_order_receipt'),'')))>0
  and position('NOT' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='orders' and policyname='buyer_update_submitted_order_receipt'),'')))>0,
  'buyer receipt update excludes every internal staff identity'
);

select ok(
  position('GATE_SECURITY' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Staff full access order_items'),'')))>0
  and position('SECURITY_CONTROL' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Staff full access order_items'),'')))>0,
  'generic staff order-item writes explicitly exclude Security Gate roles'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers insert own order_items'),'')))>0
  and position('GATE_SECURITY' in upper(coalesce((select with_check from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers insert own order_items'),'')))>0,
  'order-item insert policy cannot be reached by Security through buyer or staff branch'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers update own order_items'),'')))>0
  and position('NOT' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers update own order_items'),'')))>0,
  'buyer order-item update excludes every internal staff identity'
);

select ok(
  position('IS_INTERNAL_STAFF' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers delete own order_items'),'')))>0
  and position('NOT' in upper(coalesce((select qual from pg_policies where schemaname='public' and tablename='order_items' and policyname='Buyers delete own order_items'),'')))>0,
  'buyer order-item delete excludes every internal staff identity'
);

select * from finish();
rollback;
