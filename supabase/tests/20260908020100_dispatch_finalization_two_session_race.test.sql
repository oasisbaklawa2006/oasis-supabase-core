-- pgTAP contract for the two-session Finance hold vs dispatch finalization race.
-- The executable harness runs in scripts/test-dispatch-finalization-two-session-race.sh
-- during verify-local-schema-release-readiness (parallel psql sessions; Supabase pgTAP
-- runs as non-superuser postgres and cannot dblink locally).
begin;
select plan(4);

select ok(
  to_regclass('public.md0802_two_session_race_evidence') IS NOT NULL,
  'two-session race harness recorded evidence before pgTAP assertions'
);

select ok(
  (
    SELECT blocked_before_hold
    FROM public.md0802_two_session_race_evidence
    WHERE run_id = 'md0802-two-session-race'
  ),
  'session A blocked on eligibility lock before session B committed blocking hold'
);

select is(
  (
    SELECT (finalizer_result->>'ok')::boolean
    FROM public.md0802_two_session_race_evidence
    WHERE run_id = 'md0802-two-session-race'
  ),
  false,
  'session A finalizer rejects dispatch after session B hold commit under shared lock'
);

select ok(
  (
    SELECT finalizer_result->'blockers'->0->>'message'
    FROM public.md0802_two_session_race_evidence
    WHERE run_id = 'md0802-two-session-race'
  ) LIKE '%FINANCE_BLOCKING_HOLD_ACTIVE%'
  AND (
    SELECT order_status
    FROM public.md0802_two_session_race_evidence
    WHERE run_id = 'md0802-two-session-race'
  ) = 'cleared_for_dispatch',
  'two-session race preserves fail-closed hold truth and leaves order undispatched'
);

DROP TABLE IF EXISTS public.md0802_two_session_race_evidence;

select * from finish();
rollback;
