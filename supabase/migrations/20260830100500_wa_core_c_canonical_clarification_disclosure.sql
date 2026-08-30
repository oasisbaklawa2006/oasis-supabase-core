-- Canonical Core-generated clarification questions request missing facts; they do not disclose them.
-- Preserve the commercial disclosure classifier for all non-canonical outbound text.

create or replace function public.wa6_infer_commercial_disclosure(p_message text)
returns text[]
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
  select case
    when lower(btrim(coalesce(p_message, ''), E' \t\n\r')) = any(array[
      lower(btrim(public.wa3_clarification_question('client_identity'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('product'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('quantity'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('unit_packaging'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('delivery_address'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('payment_terms'), E' \t\n\r')),
      lower(btrim(public.wa3_clarification_question('moq_carton'), E' \t\n\r'))
    ]::text[])
      then '{}'::text[]
    else array_remove(array[
      case when p_message ~* '(₹|(^|[^a-z])rs\.?([^a-z]|$)|(^|[^a-z])price([^a-z]|$)|(^|[^a-z])rate([^a-z]|$))' then 'customer_pricing' end,
      case when p_message ~* '((^|[^a-z])moq([^a-z]|$)|minimum order|carton constraint)' then 'moq_carton' end,
      case when p_message ~* '(payment terms|credit days|advance payment)' then 'payment_terms' end,
      case when p_message ~* '(delivery address|ship to|deliver to)' then 'delivery_address' end,
      case when p_message ~* '(previous order|last order|last time)' then 'previous_orders' end,
      case when p_message ~* '(account balance|outstanding balance|amount due)' then 'account_balance' end,
      case when p_message ~* '(draft order|draft number)' then 'draft_order' end,
      case when p_message ~* '(sales order|(^|[^a-z])so[- #]?[0-9])' then 'sales_order' end
    ], null)::text[]
  end
$function$;
