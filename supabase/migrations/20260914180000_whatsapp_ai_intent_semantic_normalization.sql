-- WA-7 Stage-1B semantic intent normalization.
-- Canonical persistence guard: normalize classification and preserve explicit incomplete
-- order fragments; never invent product, SKU, quantity, price, customer, payment,
-- stock, credit or delivery facts.

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
  v_order_fragment boolean := false;
  v_quantity_fact jsonb;
  v_quantity_text text;
  v_quantity numeric;
  v_unit text := '';
  v_evidence_id text := '';
  v_order_lines jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(v_conclusion -> 'order_lines') = 'array' then
    v_order_lines := v_conclusion -> 'order_lines';
  end if;

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
    from jsonb_array_elements(v_order_lines) as line(value)
    where jsonb_typeof(line.value -> 'quantity') = 'number'
      and coalesce((line.value ->> 'quantity')::numeric, 0) > 0
  ) into v_has_quantity;

  -- Preserve an explicitly stated quantity even when the model omitted an order line
  -- because product/SKU is still unknown. This is evidence preservation, not inference.
  if not v_has_quantity and jsonb_typeof(v_conclusion -> 'explicit_facts') = 'array' then
    select fact.value
      into v_quantity_fact
    from jsonb_array_elements(v_conclusion -> 'explicit_facts') as fact(value)
    where lower(coalesce(fact.value ->> 'kind', '')) in (
      'quantity', 'order_quantity', 'order_item', 'purchase_order'
    )
      and coalesce(fact.value ->> 'value', '') ~ '[0-9]'
    order by case lower(coalesce(fact.value ->> 'kind', ''))
      when 'quantity' then 0
      when 'order_quantity' then 1
      else 2
    end
    limit 1;

    if v_quantity_fact is not null then
      v_quantity_text := substring(
        coalesce(v_quantity_fact ->> 'value', '')
        from '([0-9]+([.][0-9]+)?)'
      );
      if nullif(v_quantity_text, '') is not null then
        v_quantity := v_quantity_text::numeric;
        v_evidence_id := coalesce(v_quantity_fact ->> 'provider_message_id', '');
        if coalesce(v_quantity_fact ->> 'value', '') ~* '\mbox(es)?\M' then
          v_unit := 'boxes';
        elsif coalesce(v_quantity_fact ->> 'value', '') ~* '\mcarton(s)?\M' then
          v_unit := 'cartons';
        elsif coalesce(v_quantity_fact ->> 'value', '') ~* '\mkg\M' then
          v_unit := 'kg';
        elsif coalesce(v_quantity_fact ->> 'value', '') ~* '\m(pc|pcs|piece|pieces)\M' then
          v_unit := 'pcs';
        end if;

        v_order_lines := v_order_lines || jsonb_build_array(
          jsonb_build_object(
            'product_name', '',
            'sku', '',
            'quantity', v_quantity,
            'unit', v_unit,
            'status', 'unclear',
            'evidence_ids', case
              when v_evidence_id <> '' then jsonb_build_array(v_evidence_id)
              else '[]'::jsonb
            end
          )
        );
        v_conclusion := jsonb_set(v_conclusion, '{order_lines}', v_order_lines, true);
        v_has_quantity := true;
      end if;
    end if;
  end if;

  v_order_fragment :=
    v_evidence ~* '(BAK-[A-Z0-9-]+|BAKLAVA|BAKLAWA|SWEETS[[:space:]]+BOX|QUANTITY:[[:space:]]*[0-9]+)'
    or exists (
      select 1
      from jsonb_array_elements(
        case
          when jsonb_typeof(v_conclusion -> 'explicit_facts') = 'array'
            then v_conclusion -> 'explicit_facts'
          else '[]'::jsonb
        end
      ) as fact(value)
      where lower(coalesce(fact.value ->> 'kind', '')) in (
        'quantity', 'order_quantity', 'order_item', 'purchase_order'
      )
    );

  -- Strong prompt-injection/control-override evidence is OTHER, never executable intent.
  if v_intent in ('UNCLEAR', 'OTHER')
     and v_evidence ~* '(IGNORE[[:space:]]+(ALL|PREVIOUS|PRIOR)[[:space:]]+(RULES|INSTRUCTIONS)|AUTO[[:space:]]*CREATE[[:space:]]*ORDER|SYSTEM[[:space:]]+PROMPT|BYPASS[[:space:]]+(RULES|POLICY|CONTROLS?))'
  then
    v_intent := 'OTHER';

  -- A later explicit correction in an order packet is an amendment, not a new order.
  elsif v_intent in ('NEW_ORDER', 'ORDER', 'AMENDMENT') and v_has_correction then
    v_intent := 'AMENDMENT';

  -- Catalogue/product-list evidence without an explicit quantity/order directive is an enquiry.
  elsif v_intent in ('UNCLEAR', 'ENQUIRY', 'SPECIFICATION_QUERY', 'SPECIFICATION')
        and v_evidence ~* 'CATALOG(UE)?'
        and not v_has_quantity
        and v_evidence !~* '(ORDER|SEND|SHIP|NEED|REQUIRE|WANT|BOOK)[[:space:]]+[0-9]+([.][0-9]+)?'
  then
    v_intent := 'ENQUIRY';

  -- In the governed WhatsApp order-capture channel, a product/quantity fragment can be
  -- a potentially valid incomplete order. Route it to NEW_ORDER clarification rather
  -- than losing it as an enquiry/unclear case. Explicit non-order evidence is excluded.
  elsif v_intent in ('UNCLEAR', 'ENQUIRY', 'SPECIFICATION_QUERY', 'SPECIFICATION')
        and v_order_fragment
        and v_evidence !~* 'CATALOG(UE)?'
        and v_evidence !~* '(UPI[[:space:]]+PAID|PAYMENT[[:space:]]+PROOF|TRANSACTION[[:space:]]+ID|\mUTR\M)'
        and v_evidence !~* '(COMPLAINT|DAMAGED|BROKEN[[:space:]]+PRODUCT)'
  then
    v_intent := 'NEW_ORDER';
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
  'Deterministic WA resolver-policy/v2 semantic normalization. Preserves explicit incomplete order fragments but never invents commercial facts or grants execution authority.';
