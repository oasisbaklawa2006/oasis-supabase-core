-- Contract test anchor for 20261011150000_mc631_so_recordable_progressive_identity.sql
select plan(1);

select has_function(
  'public',
  'validate_sales_order_so_recordable_readiness',
  array['jsonb'],
  'mc631_so_recordable_progressive_identity defines SO_RECORDABLE readiness gate'
);

select * from finish();
