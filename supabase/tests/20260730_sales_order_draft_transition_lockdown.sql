begin;

select plan(8);

select has_function(
  'public',
  'transition_sales_order_draft_status',
  array['uuid','text','text','text','uuid','text','text','text','uuid','text','jsonb'],
  'generic transition RPC exists'
);

select function_privs_are(
  'public',
  'transition_sales_order_draft_status',
  array['uuid','text','text','text','uuid','text','text','text','uuid','text','jsonb'],
  'anon',
  array[]::text[],
  'anon cannot execute generic transition RPC'
);

select function_privs_are(
  'public',
  'transition_sales_order_draft_status',
  array['uuid','text','text','text','uuid','text','text','text','uuid','text','jsonb'],
  'authenticated',
  array[]::text[],
  'authenticated cannot execute generic transition RPC'
);

select function_privs_are(
  'public',
  'transition_sales_order_draft_status',
  array['uuid','text','text','text','uuid','text','text','text','uuid','text','jsonb'],
  'service_role',
  array['EXECUTE'],
  'service role retains generic transition execution'
);

select has_function(
  'public',
  'submit_sales_order_draft_for_review_atomic',
  array['uuid','text','jsonb','integer','jsonb','jsonb','uuid','text','jsonb'],
  'specialized submit RPC exists'
);

select has_function(
  'public',
  'approve_sales_order_draft_for_so_atomic',
  array['uuid','text','uuid','text','text','jsonb'],
  'specialized approve RPC exists'
);

select has_function(
  'public',
  'reject_sales_order_draft_atomic',
  array['uuid','uuid','text','text','text','jsonb'],
  'specialized reject RPC exists'
);

select has_function(
  'public',
  'update_sales_order_draft_operator_final',
  array['uuid','text','jsonb','integer','jsonb','jsonb','uuid','text','jsonb'],
  'specialized operator-final RPC exists'
);

select * from finish();
rollback;
