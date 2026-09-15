begin;

-- Contract for migration 20260914180100_whatsapp_ai_intent_normalizer_policy_scope.sql.
select plan(4);

select ok(
  to_regprocedure('public.whatsapp_normalize_ai_interpretation_before_insert_v2()') is not null,
  'semantic normalization trigger function exists'
);

select ok(
  position('wa-resolver-policy/v1' in pg_get_functiondef(
    'public.whatsapp_normalize_ai_interpretation_before_insert_v2()'::regprocedure
  )) > 0,
  'trigger explicitly recognizes governed resolver policy v1'
);

select ok(
  position('not in' in lower(pg_get_functiondef(
    'public.whatsapp_normalize_ai_interpretation_before_insert_v2()'::regprocedure
  ))) > 0,
  'trigger fails open for non-wa resolver contracts instead of rewriting them'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.whatsapp_packet_ai_interpretations'::regclass
      and tgname = 'whatsapp_packet_ai_interpretations_intent_v2'
      and not tgisinternal
  ),
  'scoped trigger remains attached to canonical interpretation table'
);

select * from finish();
rollback;
