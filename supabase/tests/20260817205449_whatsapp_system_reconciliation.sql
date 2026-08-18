begin;
-- Contract coverage for recovered historical migration 20260817205449.
select plan(2);
select has_column('public', 'whatsapp_reconciliation_runs', 'reconciled_actor_type', 'whatsapp_reconciliation_runs.reconciled_actor_type exists');
select has_column('public', 'whatsapp_reconciliation_exceptions', 'owner_team', 'whatsapp_reconciliation_exceptions.owner_team exists');
select * from finish();
rollback;
