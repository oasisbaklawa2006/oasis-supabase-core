begin;
-- Core #486 supplementary regression coverage for PR #505.
-- Preserve original 29-assertion provenance test and immutable SQL migration.
-- Read-only parser exercises; rollback-only. Never execute on production.
select plan(12);

select is(
  (select present from public.catalogue_parse_typed_content_quantity_v1('{"packing":{}}'::jsonb)),
  false, 'missing typed quantity under packing remains legacy-compatible'
);
select is(
  (select present from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"primary_pack_type":"box"}}'::jsonb)),
  false, 'unrelated packing attributes do not infer quantity'
);
select is(
  (select pcs_per_pack from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":1,"unit":"pcs"}}}'::jsonb)),
  1::numeric, 'one explicit piece remains one'
);
select is(
  (select net_weight_grams from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":0.125,"unit":"g"}}}'::jsonb)),
  0.125::numeric, 'positive fractional gram precision is preserved'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":0,"unit":"g"}}}'::jsonb)$$,
  'P0001', null, 'zero gram content denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":-0.5,"unit":"kg"}}}'::jsonb)$$,
  'P0001', null, 'negative kilogram content denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":true,"unit":"pcs"}}}'::jsonb)$$,
  'P0001', null, 'boolean quantity denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":null,"unit":"pcs"}}}'::jsonb)$$,
  'P0001', null, 'explicit null numeric value denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":2,"unit":null}}}'::jsonb)$$,
  'P0001', null, 'explicit null unit denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":2,"unit":"PCS"}}}'::jsonb)$$,
  'P0001', null, 'unsupported uppercase unit denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":{"value":2,"unit":"pcs","conversion":1}}}'::jsonb)$$,
  'P0001', null, 'extra conversion attribute denied'
);
select throws_ok(
  $$select * from public.catalogue_parse_typed_content_quantity_v1('{"packing":{"content_quantity":[{"value":2,"unit":"pcs"}]}}'::jsonb)$$,
  'P0001', null, 'array in place of typed object denied'
);
select * from finish();
rollback;
