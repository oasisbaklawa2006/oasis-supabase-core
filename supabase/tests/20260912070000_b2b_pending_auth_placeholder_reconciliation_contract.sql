begin;

-- Contract for 20260912070000_b2b_pending_auth_placeholder_reconciliation.sql
select plan(2);

select has_function(
  'public', 'inspect_b2b_pending_phone_placeholder_v1', array['text'],
  '20260912070000 preflight authority is installed'
);
select has_function(
  'public', 'reconcile_b2b_pending_phone_placeholder_v1', array['text','uuid','uuid'],
  '20260912070000 reconciliation authority is installed'
);

select * from finish();
rollback;
