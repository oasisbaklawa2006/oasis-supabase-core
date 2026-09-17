-- Contract for 20260917143000_customer_support_ticket_idempotency.sql
begin;

select plan(11);

select has_column(
  'public', 'support_tickets', 'idempotency_key',
  'support_tickets stores the buyer retry key'
);

select ok(
  exists (
    select 1
    from pg_indexes
    where schemaname='public'
      and tablename='support_tickets'
      and indexname='support_tickets_buyer_idempotency_uidx'
      and indexdef like '%UNIQUE INDEX%'
      and indexdef like '%company_id, user_id, idempotency_key%'
      and indexdef like '%WHERE (idempotency_key IS NOT NULL)%'
  ),
  'support-ticket retry keys are unique per buyer/company when present'
);

select ok(
  to_regprocedure('public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)') is null,
  'legacy non-idempotent support-ticket mutation is removed'
);

select has_function(
  'public',
  'submit_customer_support_ticket_v1',
  array['text','uuid','text','text','text','integer'],
  'idempotent support-ticket mutation exists'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)',
    'EXECUTE'
  ),
  'support-ticket mutation remains authenticated-only'
);

select ok(
  (select prosecdef
   from pg_proc
   where oid='public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure),
  'support-ticket mutation remains SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public, auth']
   from pg_proc
   where oid='public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure),
  'support-ticket mutation keeps a fixed search_path'
);

select ok(
  pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%pg_advisory_xact_lock%'
  and pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%SUPPORT_TICKET_IDEMPOTENCY_CONFLICT%',
  'support-ticket mutation serializes retries and rejects key reuse with changed payload'
);

select ok(
  pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%t.company_id = v_company_id%'
  and pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%t.user_id = v_uid%',
  'idempotency lookup is scoped to the authenticated buyer company and user'
);

select ok(
  pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%is distinct from p_order_id::text%'
  and pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%is distinct from v_description%'
  and pg_get_functiondef(
    'public.submit_customer_support_ticket_v1(text,uuid,text,text,text,integer)'::regprocedure
  ) like '%is distinct from p_quantity_affected%',
  'same idempotency key cannot be replayed with materially different ticket content'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.support_tickets'::regclass
      and conname='support_tickets_idempotency_key_length'
  ),
  'idempotency key length is bounded in storage'
);

select * from finish();
rollback;
