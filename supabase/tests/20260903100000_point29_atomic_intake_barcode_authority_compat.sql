-- Contract for preview ledger compatibility stub 20260903100000_point29_atomic_intake_barcode_authority.sql
begin;

select plan(1);

select has_function(
  'public',
  'catalogue_extract_reviewed_intake_barcode',
  array['jsonb'],
  'preview compat stub leaves forward Point 29 intake-barcode patch applied by 20260904030100'
);

select * from finish();
rollback;
