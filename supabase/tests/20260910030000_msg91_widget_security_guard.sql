-- Contract for 20260910030000_msg91_widget_security_guard.sql.
-- Proves the public MSG91 verification endpoint has durable service-role-only
-- rate/replay authority before any identity/session work.

select plan(14);

select has_table(
  'public',
  'msg91_otp_security_events',
  'MSG91 private rate/replay ledger exists'
);

select has_function(
  'public',
  'check_msg91_widget_attempt_v1',
  array['text'],
  'MSG91 attempt-rate RPC exists'
);

select has_function(
  'public',
  'claim_msg91_widget_token_v1',
  array['text','text','text'],
  'MSG91 verified-token claim RPC exists'
);

select ok(
  not has_function_privilege('anon', 'public.check_msg91_widget_attempt_v1(text)', 'EXECUTE'),
  'anon cannot call MSG91 attempt-rate authority'
);

select ok(
  not has_function_privilege('authenticated', 'public.check_msg91_widget_attempt_v1(text)', 'EXECUTE'),
  'authenticated cannot call MSG91 attempt-rate authority directly'
);

select ok(
  has_function_privilege('service_role', 'public.check_msg91_widget_attempt_v1(text)', 'EXECUTE'),
  'service_role may call MSG91 attempt-rate authority'
);

select ok(
  not has_function_privilege('anon', 'public.claim_msg91_widget_token_v1(text,text,text)', 'EXECUTE'),
  'anon cannot claim MSG91 verified tokens'
);

select ok(
  not has_function_privilege('authenticated', 'public.claim_msg91_widget_token_v1(text,text,text)', 'EXECUTE'),
  'authenticated cannot claim MSG91 verified tokens directly'
);

select ok(
  has_function_privilege('service_role', 'public.claim_msg91_widget_token_v1(text,text,text)', 'EXECUTE'),
  'service_role may claim MSG91 verified tokens'
);

truncate table public.msg91_otp_security_events restart identity;

select is(
  (public.check_msg91_widget_attempt_v1(repeat('a', 64))->>'ok')::boolean,
  true,
  'first hashed-origin attempt is admitted'
);

select is(
  (public.claim_msg91_widget_token_v1(repeat('b', 64), repeat('c', 64), repeat('a', 64))->>'ok')::boolean,
  true,
  'first verified token claim is admitted'
);

select is(
  public.claim_msg91_widget_token_v1(repeat('b', 64), repeat('c', 64), repeat('a', 64))->>'reason',
  'access_token_replayed',
  'same verified token digest is rejected on replay'
);

select ok(
  pg_get_functiondef('public.check_msg91_widget_attempt_v1(text)'::regprocedure)
    like '%v_count >= 20%'
  and pg_get_functiondef('public.check_msg91_widget_attempt_v1(text)'::regprocedure)
    like '%10 minutes%',
  'attempt authority enforces a bounded ten-minute IP window'
);

select ok(
  pg_get_functiondef('public.claim_msg91_widget_token_v1(text,text,text)'::regprocedure)
    like '%v_phone_count >= 5%'
  and pg_get_functiondef('public.claim_msg91_widget_token_v1(text,text,text)'::regprocedure)
    like '%v_ip_count >= 10%'
  and pg_get_functiondef('public.claim_msg91_widget_token_v1(text,text,text)'::regprocedure)
    like '%access_token_replayed%',
  'verified-token authority enforces phone/IP limits and replay rejection'
);

select * from finish();
