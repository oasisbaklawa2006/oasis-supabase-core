begin;

-- Contract coverage for Task 5 CERT-SEC-002 hardening.
select plan(15);

select has_table(
  'public',
  'announcement_counter_receipts',
  'announcement counter receipt table exists'
);

select ok(
  (select relrowsecurity
     from pg_class
    where oid = 'public.announcement_counter_receipts'::regclass),
  'announcement counter receipts have RLS enabled'
);

select is(
  has_table_privilege('authenticated', 'public.announcement_counter_receipts', 'SELECT'),
  false,
  'authenticated clients cannot read analytics receipts directly'
);

select is(
  has_function_privilege('anon', 'public.increment_announcement_counter(uuid,text)', 'EXECUTE'),
  false,
  'anonymous callers cannot execute announcement counter RPC'
);

select is(
  has_function_privilege('public', 'public.increment_announcement_counter(uuid,text)', 'EXECUTE'),
  false,
  'PUBLIC cannot execute announcement counter RPC'
);

select is(
  has_function_privilege('authenticated', 'public.increment_announcement_counter(uuid,text)', 'EXECUTE'),
  true,
  'authenticated callers retain the legacy RPC surface'
);

select ok(
  (select prosecdef
     from pg_proc
    where oid = 'public.increment_announcement_counter(uuid,text)'::regprocedure),
  'announcement counter RPC is SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
     from pg_proc
    where oid = 'public.increment_announcement_counter(uuid,text)'::regprocedure),
  'announcement counter RPC uses a fixed search_path'
);

insert into auth.users (id, email) values
  ('a1100000-0000-0000-0000-000000000001', 'announcement-counter-1@example.invalid'),
  ('a1100000-0000-0000-0000-000000000002', 'announcement-counter-2@example.invalid');

insert into public.premium_announcements (
  id, title, priority, target_audience, display_duration, trigger_delay
) values (
  'a1200000-0000-0000-0000-000000000001',
  'Task 5 analytics hardening fixture',
  'greeting',
  'all',
  8,
  10
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a1100000-0000-0000-0000-000000000001';

select lives_ok(
  $$select public.increment_announcement_counter(
      'a1200000-0000-0000-0000-000000000001', 'view'
    )$$,
  'first authenticated view increment succeeds'
);

select lives_ok(
  $$select public.increment_announcement_counter(
      'a1200000-0000-0000-0000-000000000001', 'view'
    )$$,
  'replayed view increment is accepted as an idempotent no-op'
);

select is(
  (select view_count
     from public.premium_announcements
    where id = 'a1200000-0000-0000-0000-000000000001'),
  1,
  'same actor replay increments view exactly once'
);

select is(
  (select count(*)::integer
     from public.announcement_counter_receipts
    where announcement_id = 'a1200000-0000-0000-0000-000000000001'
      and actor_id = 'a1100000-0000-0000-0000-000000000001'
      and counter_name = 'view'),
  1,
  'same actor replay creates exactly one receipt'
);

set local request.jwt.claim.sub = 'a1100000-0000-0000-0000-000000000002';

select lives_ok(
  $$select public.increment_announcement_counter(
      'a1200000-0000-0000-0000-000000000001', 'view'
    )$$,
  'a distinct authenticated actor can contribute one view'
);

select is(
  (select view_count
     from public.premium_announcements
    where id = 'a1200000-0000-0000-0000-000000000001'),
  2,
  'two distinct authenticated actors produce two views'
);

select throws_like(
  $$select public.increment_announcement_counter(
      'a1200000-0000-0000-0000-000000000001', 'invented'
    )$$,
  '%ANNOUNCEMENT_COUNTER_INVALID%',
  'unknown counter type fails closed'
);

select * from finish();
rollback;
