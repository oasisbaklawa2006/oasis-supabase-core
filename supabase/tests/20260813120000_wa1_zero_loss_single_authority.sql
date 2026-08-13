-- Contract for migration 20260813120000_wa1_zero_loss_single_authority.sql.
begin;
select plan(21);

select has_table('public','whatsapp_potential_orders','potential-order authority exists');
select has_table('public','whatsapp_potential_order_audit_log','append-only audit exists');
select has_view('public','whatsapp_potential_order_reconciliation','reconciliation projection exists');
select has_function('public','capture_whatsapp_potential_order',array['uuid','boolean','boolean','jsonb']);
select has_function('public','transition_whatsapp_potential_order',array['uuid','text','uuid','text','text','timestamptz','uuid','uuid','text','timestamptz','jsonb']);
select col_is_pk('public','whatsapp_potential_orders','id','potential-order id is primary key');
select is((select count(*) from pg_indexes where schemaname='public' and tablename='whatsapp_potential_orders' and indexdef like '%UNIQUE%source_fingerprint%' and indexdef like '%ACTIVE_PENDING%'),1::bigint,'open forward fingerprint is idempotent without suppressing later terminal repeats');
select ok(exists(select 1 from pg_trigger where tgrelid='public.whatsapp_potential_order_audit_log'::regclass and tgname='whatsapp_potential_order_audit_immutable' and not tgisinternal),'audit is append-only');
select ok(exists(select 1 from pg_trigger where tgrelid='public.whatsapp_potential_orders'::regclass and tgname='whatsapp_potential_order_governed_update' and not tgisinternal),'direct lifecycle mutation is blocked');
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name in ('whatsapp_potential_orders','whatsapp_potential_order_audit_log') and grantee in ('anon','authenticated') and privilege_type in ('INSERT','UPDATE','DELETE')$$,'clients cannot directly mutate WA-1 authority');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name='capture_whatsapp_potential_order' and grantee in ('PUBLIC','anon','authenticated')$$,'only trusted ingress can capture potential orders');
select isnt_empty($$select 1 from pg_proc where oid='public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb)'::regprocedure and prosecdef$$,'transition is guarded definer authority');
select isnt_empty($$select 1 from pg_proc where oid='public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%APPROVED_FOR_SO%' and pg_get_functiondef(oid) like '%promoted_order_id%'$$,'conversion proves Core promotion');
select isnt_empty($$select 1 from information_schema.check_constraints where constraint_name='whatsapp_potential_orders_outcome_link'$$,'terminal outcomes require authoritative linkage');
select isnt_empty($$select 1 from pg_views where schemaname='public' and viewname='whatsapp_potential_order_reconciliation' and definition like '%unaccounted_potential_orders%'$$,'reconciliation exposes unaccounted potential orders');
select isnt_empty($$select 1 from pg_views where schemaname='public' and viewname='whatsapp_potential_order_reconciliation' and definition like '%commercial_eligible%' and definition not like '%studio_fanout%'$$,'reconciliation counts only persisted commercial eligibility');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_potential_order(uuid,boolean,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%30 minutes%' and pg_get_functiondef(oid) like '%SOURCE_EVIDENCE_ATTACHED%'$$,'fragments corrections and forwards remain one governed intake');
select isnt_empty($$select 1 from pg_indexes where schemaname='public' and indexname='whatsapp_potential_orders_evidence_gin_idx'$$,'evidence replay lookup has GIN support');
select isnt_empty($$select 1 from pg_indexes where schemaname='public' and indexname='whatsapp_potential_orders_sender_open_idx' and indexdef like '%sender_key, last_evidence_at DESC%' and indexdef like '%ACTIVE_PENDING%'$$,'open sender merge lookup is indexed');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_potential_order(uuid,boolean,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%app.wa1_governed_mutation%off%'$$,'capture resets mutation guard');
select isnt_empty($$select 1 from pg_proc where oid='public.wa1_direct_mutation_blocked()'::regprocedure and pg_get_functiondef(oid) like '%WA1_DELETE_FORBIDDEN%'$$,'delete always fails closed');

select * from finish();
rollback;
