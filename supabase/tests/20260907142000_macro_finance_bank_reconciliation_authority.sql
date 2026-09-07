-- Contract for migration 20260907142000_macro_finance_bank_reconciliation_authority.sql.

select plan(31);

select has_table('public', 'bank_settlement_import_batches', 'bank settlement import batches exist');
select has_table('public', 'bank_settlement_transactions', 'bank settlement transactions exist');
select has_table('public', 'bank_reconciliation_matches', 'bank reconciliation matches exist');
select has_table('public', 'bank_reconciliation_cases', 'bank reconciliation cases exist');
select has_table('public', 'bank_reconciliation_case_events', 'bank reconciliation case events exist');
select has_table('public', 'bank_reconciliation_idempotency', 'bank reconciliation idempotency exists');

select has_function('public', 'import_bank_settlement_batch_v1', array['text','text','jsonb','text','text','uuid'], 'import batch RPC exists');
select has_function('public', 'auto_match_bank_settlement_batch_v1', array['uuid','text','text','uuid'], 'auto match RPC exists');
select has_function('public', 'resolve_bank_reconciliation_case_v1', array['uuid','text','text','uuid','text','text','text','uuid'], 'resolve case RPC exists');
select has_function('public', 'get_bank_reconciliation_summary_v1', array['uuid'], 'reconciliation summary RPC exists');
select has_function('public', 'get_bank_reconciliation_tally_projection_v1', array['uuid'], 'tally projection RPC exists');

select ok(not has_table_privilege('authenticated', 'public.bank_settlement_transactions', 'INSERT'), 'no direct bank transaction insert');
select ok(not has_table_privilege('authenticated', 'public.bank_reconciliation_matches', 'INSERT'), 'no direct reconciliation match insert');
select ok(not has_table_privilege('service_role', 'public.bank_settlement_import_batches', 'INSERT'), 'service role cannot direct-write import batches');

select ok(pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'import requires Finance+AAL2');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'auto match requires Finance+AAL2');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'case resolution requires Finance+AAL2');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_MAKER_CHECKER%', 'sensitive case resolution enforces maker-checker');

select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%ambiguous%', 'auto match opens ambiguous cases instead of forcing matches');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%order_payments%', 'auto match uses canonical order_payments truth');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%UTR_EXACT%', 'auto match supports UTR exact rule');
select ok(not has_function_privilege('service_role', 'public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)', 'EXECUTE'), 'service role cannot import bank batches');

select ok(pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%BANK_SETTLEMENT_IMPORT_IDEMPOTENCY_CONFLICT%', 'import is idempotent');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_MATCH_IDEMPOTENCY_CONFLICT%', 'auto match is idempotent');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_CASE_TERMINAL%', 'terminal cases reject stale replay');

select ok(pg_get_functiondef('public.prevent_bank_reconciliation_mutation()'::regprocedure) like '%BANK_RECONCILIATION_APPEND_ONLY%', 'matches and case events are append-only');
select ok(pg_get_functiondef('public.get_bank_reconciliation_summary_v1(uuid)'::regprocedure) like '%BANK_RECONCILIATION_SUMMARY_INTERNAL_ONLY%', 'summary is internal-only');
select ok(pg_get_functiondef('public.get_bank_reconciliation_tally_projection_v1(uuid)'::regprocedure) like '%duplicate_gl%', 'tally projection declares no duplicate GL');
select ok(pg_get_functiondef('public.get_bank_reconciliation_tally_projection_v1(uuid)'::regprocedure) like '%tally_projection_only%', 'tally projection is facts-only');

select ok(has_function_privilege('authenticated', 'public.get_bank_reconciliation_summary_v1(uuid)', 'EXECUTE'), 'authenticated internal actor can read summary');
select ok(not has_function_privilege('service_role', 'public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)', 'EXECUTE'), 'service role cannot resolve reconciliation cases');

select * from finish();
