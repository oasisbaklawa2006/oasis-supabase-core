-- Contract for migration: 20260809200000_lockdown_pricing_moq_direct_writes.sql
begin;

select plan(10);

select table_privs_are(
  'public',
  'product_pricing_rules',
  'anon',
  array['SELECT'],
  'anon can only select product_pricing_rules'
);

select table_privs_are(
  'public',
  'product_pricing_rules',
  'authenticated',
  array['SELECT'],
  'authenticated can only select product_pricing_rules'
);

select table_privs_are(
  'public',
  'product_pricing_rules',
  'service_role',
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'],
  'service_role retains full product_pricing_rules access (untouched by this migration)'
);

select table_privs_are(
  'public',
  'product_moq_rules',
  'anon',
  array['SELECT'],
  'anon can only select product_moq_rules'
);

select table_privs_are(
  'public',
  'product_moq_rules',
  'authenticated',
  array['SELECT'],
  'authenticated can only select product_moq_rules'
);

select table_privs_are(
  'public',
  'product_moq_rules',
  'service_role',
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'],
  'service_role retains full product_moq_rules access (untouched by this migration)'
);

select has_function(
  'public',
  'approve_catalogue_pricing_draft',
  array['uuid'],
  'approve_catalogue_pricing_draft still exists and is untouched by this migration'
);

select results_eq(
  $$ select prosecdef
     from pg_proc
     where oid = 'public.approve_catalogue_pricing_draft(uuid)'::regprocedure $$,
  array[true],
  'approve_catalogue_pricing_draft remains SECURITY DEFINER'
);

select has_function(
  'public',
  'approve_catalogue_moq_draft',
  array['uuid'],
  'approve_catalogue_moq_draft still exists and is untouched by this migration'
);

select results_eq(
  $$ select prosecdef
     from pg_proc
     where oid = 'public.approve_catalogue_moq_draft(uuid)'::regprocedure $$,
  array[true],
  'approve_catalogue_moq_draft remains SECURITY DEFINER'
);

select * from finish();
rollback;
