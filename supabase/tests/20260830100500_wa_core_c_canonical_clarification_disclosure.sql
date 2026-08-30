-- Contract for migration 20260830100500_wa_core_c_canonical_clarification_disclosure.sql
begin;

select plan(13);

select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('client_identity')), '{}'::text[], 'canonical client clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('product')), '{}'::text[], 'canonical product clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('quantity')), '{}'::text[], 'canonical quantity clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('unit_packaging')), '{}'::text[], 'canonical packaging clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('delivery_address')), '{}'::text[], 'canonical delivery-address clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('payment_terms')), '{}'::text[], 'canonical payment-terms clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(public.wa3_clarification_question('moq_carton')), '{}'::text[], 'canonical MOQ clarification is not disclosure');
select is(public.wa6_infer_commercial_disclosure(upper(public.wa3_clarification_question('delivery_address')) || E'\n'), '{}'::text[], 'canonical clarification matching tolerates case and surrounding whitespace');

select is(public.wa6_infer_commercial_disclosure('Your delivery address is 123 Main Street'), array['delivery_address']::text[], 'actual delivery-address disclosure remains classified');
select is(public.wa6_infer_commercial_disclosure('Your sales order SO-123 is confirmed'), array['sales_order']::text[], 'sales-order disclosure remains classified');
select is(public.wa6_infer_commercial_disclosure('SO123 is confirmed'), array['sales_order']::text[], 'compact sales-order identifier remains classified');
select is(public.wa6_infer_commercial_disclosure('So sorry, please clarify the request'), '{}'::text[], 'ordinary word so is not a sales-order disclosure');
select is(public.wa6_infer_commercial_disclosure('Your account balance is pending'), array['account_balance']::text[], 'account-balance disclosure remains classified');

select * from finish();
rollback;
