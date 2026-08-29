-- Contract for migration 20260830100500_wa_core_c_canonical_clarification_disclosure.sql
begin;

select plan(4);

select is(
  public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('delivery_address')),
  '{}'::text[],
  'canonical delivery-address clarification question is not treated as disclosure'
);

select is(
  public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('payment_terms')),
  '{}'::text[],
  'canonical payment-terms clarification question is not treated as disclosure'
);

select is(
  public.wa6_infer_commercial_disclosure('Your delivery address is 123 Main Street'),
  array['delivery_address']::text[],
  'actual delivery-address disclosure remains blocked/classified'
);

select is(
  public.wa6_infer_commercial_disclosure('Your sales order SO-123 is confirmed'),
  array['sales_order']::text[],
  'sales-order disclosure remains classified'
);

select * from finish();
rollback;
