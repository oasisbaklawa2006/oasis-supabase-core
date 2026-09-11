-- pgTAP contract for the two-session Finance hold vs dispatch finalization race.
-- Executable harness: scripts/test-dispatch-finalization-two-session-race.sh
-- (parallel psql sessions during verify-local-schema-release-readiness).
begin;
select plan(8);

select ok(
  to_regclass('public.md0802_two_session_race_evidence') IS NOT NULL,
  'two-session race harness recorded evidence before pgTAP assertions'
);

select ok(
  (
    SELECT peer_blocked
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'hold_first'
  ),
  'scenario B: finalizer blocked on eligibility lock while hold held locks first'
);

select is(
  (
    SELECT (finalizer_result->>'ok')::boolean
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'hold_first'
  ),
  false,
  'scenario B: finalizer rejects dispatch after hold commits under shared lock'
);

select ok(
  (
    SELECT order_status = 'cleared_for_dispatch'
      AND blocking_hold_count = 1
      AND clearance_decision = 'GRANTED'
      AND finalizer_result->'blockers'->0->>'message' LIKE '%FINANCE_BLOCKING_HOLD_ACTIVE%'
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'hold_first'
  ),
  'scenario B: authoritative finance/order state remains fail-closed and undispatched'
);

select ok(
  (
    SELECT peer_blocked
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'finalizer_holds_lock'
  ),
  'scenario A: hold blocked on eligibility lock while finalizer held locks first'
);

select is(
  (
    SELECT (finalizer_result->>'ok')::boolean
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'finalizer_holds_lock'
  ),
  false,
  'scenario A: post-hold finalization rejects dispatch fail-closed'
);

select ok(
  (
    SELECT order_status = 'cleared_for_dispatch'
      AND blocking_hold_count = 1
      AND clearance_decision = 'GRANTED'
      AND finalizer_result->'blockers'->0->>'message' LIKE '%FINANCE_BLOCKING_HOLD_ACTIVE%'
    FROM public.md0802_two_session_race_evidence
    WHERE scenario = 'finalizer_holds_lock'
  ),
  'scenario A: committed blocking hold prevents dispatch without mutating clearance truth'
);

select is(
  (SELECT count(*)::integer FROM public.md0802_two_session_race_evidence),
  2,
  'two-session harness recorded both interleavings'
);

select * from finish();
rollback;
