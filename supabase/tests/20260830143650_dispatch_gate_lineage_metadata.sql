-- Contract for migration 20260830143650_dispatch_gate_lineage_metadata.sql.

select plan(3);
select has_column('public','dispatch_gate_decisions','metadata','gate decisions expose structured lineage metadata');
select col_type_is('public','dispatch_gate_decisions','metadata','jsonb','gate lineage metadata is jsonb');
select is((select column_default from information_schema.columns where table_schema='public' and table_name='dispatch_gate_decisions' and column_name='metadata'), '''{}''::jsonb', 'gate lineage metadata defaults to empty object');
select * from finish();
