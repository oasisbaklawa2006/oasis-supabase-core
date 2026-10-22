-- Contract anchor for 20261011160000_mc631_order_pending_governance_tasks.sql
select plan(2);

select has_table(
  'public',
  'sales_order_governance_pending_tasks',
  'MC#631 pending governance tasks table exists'
);

select has_function(
  'public',
  'sync_sales_order_governance_pending_tasks_from_draft',
  array['uuid', 'uuid'],
  'MC#631 pending task materializer exists'
);

select * from finish();
