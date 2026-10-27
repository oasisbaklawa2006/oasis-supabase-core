begin;
select plan(2);
select ok(exists(select 1 from supabase_migrations.schema_migrations where version = '20261022160000'), 'preview compatibility version is recorded on a clean replay');
select ok(exists(select 1 from supabase_migrations.schema_migrations where version = '20261029020000'), 'forward catalogue migration is recorded on a clean replay');
select * from finish();
rollback;
