-- WA-7 Stage-1B semantic intent normalization.
-- Canonical persistence guard: normalize classification only; never invent or mutate
-- product, SKU, quantity, price, customer, payment, stock, credit or delivery facts.

create or replace function public.normalize_whatsapp_ai_interpretation_v2(
  p_interpretation jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_result jsonb := coalesce(p_interpretation, '{}'::jsonb);
  v_conclusion jsonb := coalesce(v_result -> 'conclusion', '{}'::jsonb);
  v_intent text := upper(coalesce(v_conclusion ->> 'intent', 'UNCLEAR'));
  v_evidence text := concat_ws(
    E'\n',
    coalesce(v_result ->> 'normalized_text', ''),
    coalesce(v_result ->> 'extracted_text', '')
  );
  v_has_correction boolean := false;
  v_has_quantity boolean := false;
begin
  select exists (
    select 1
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_conclusion -> 'corrections') = 'array'
          then v_conclusion -> 'corrections'
        else '[]'::jsonb
      end
    ) as correction(value)
    where nullif(btrim(correction.value ->> 'provider_message_id'), '') is not null
      and nullif(btrim(correction.value ->> 'replacement'), '') is not null
  ) into v_has_correction;

  select exists (
    select 1
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_conclusion -> 'order_lines') = 'array'
          then v_conclusion -> 'order_lines'
        else '[]'::jsonb
      end
    ) as line(value)
    where jsonb_typeof(line.value -> 'quantity') = 'number'
      and coalesce((line.value ->> 'quantity')::numeric, 0) > 0
  ) into v_has_quantity;

  -- Strong prompt-injection/control-override evidence is OTHER, never executable intent.
  if v_intent in ('UNCLEAR', 'OTHER')
     and v_evidence ~* '\m(IGNORE[[:space:]]+(ALL|PREVIOUS|PRIOR)[[:space:]]+(RULES|INSTRUCTIONS)|AUTO[[:space:]]*CREATE[[:space:]]*ORDER|SYSTEM[[:space:]]+PROMPT|BYPASS[[:space:]]+(RULES|POLICY|CONTROLS?))\M'
  then
    v_intent := 'OTHER';

  -- A later explicit correction in an order packet is an amendment, not a new order.
  elsif v_intent in ('NEW_ORDER', 'AMENDMENT') and v_has_correction then
    v_intent := 'AMENDMENT';

  -- Catalogue/product-list evidence without an explicit quantity/order directive is an enquiry.
  elsif v_intent in ('UNCLEAR', 'ENQUIRY')
        and v_evidence ~* '\mCATALOG(UE)?\M'
        and not v_has_quantity
        and v_evidence !~* '\m(ORDER|SEND|SHIP|NEED|REQUIRE|WANT|BOOK)[[:space:]]+[0-9]+([.][0-9]+)?\M'
  then
    v_intent := 'ENQUIRY';
  end if;

  v_conclusion := jsonb_set(v_conclusion, '{intent}', to_jsonb(v_intent), true);
  return jsonb_set(v_result, '{conclusion}', v_conclusion, true);
end;
$$;

revoke all on function public.normalize_whatsapp_ai_interpretation_v2(jsonb) from public;
revoke all on function public.normalize_whatsapp_ai_interpretation_v2(jsonb) from anon;
revoke all on function public.normalize_whatsapp_ai_interpretation_v2(jsonb) from authenticated;
grant execute on function public.normalize_whatsapp_ai_interpretation_v2(jsonb) to service_role;

create or replace function public.whatsapp_normalize_ai_interpretation_before_insert_v2()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
begin
  new.interpretation := public.normalize_whatsapp_ai_interpretation_v2(new.interpretation);
  if new.resolver_policy_version is null
     or new.resolver_policy_version = ''
     or new.resolver_policy_version = 'wa-resolver-policy/v1'
  then
    new.resolver_policy_version := 'wa-resolver-policy/v2';
  end if;
  return new;
end;
$$;

revoke all on function public.whatsapp_normalize_ai_interpretation_before_insert_v2() from public;
revoke all on function public.whatsapp_normalize_ai_interpretation_before_insert_v2() from anon;
revoke all on function public.whatsapp_normalize_ai_interpretation_before_insert_v2() from authenticated;
grant execute on function public.whatsapp_normalize_ai_interpretation_before_insert_v2() to service_role;

drop trigger if exists whatsapp_packet_ai_interpretations_intent_v2
  on public.whatsapp_packet_ai_interpretations;

create trigger whatsapp_packet_ai_interpretations_intent_v2
before insert on public.whatsapp_packet_ai_interpretations
for each row
execute function public.whatsapp_normalize_ai_interpretation_before_insert_v2();

comment on function public.normalize_whatsapp_ai_interpretation_v2(jsonb) is
  'Deterministic WA resolver-policy/v2 intent normalization. Classification only; does not invent commercial facts or grant execution authority.';
