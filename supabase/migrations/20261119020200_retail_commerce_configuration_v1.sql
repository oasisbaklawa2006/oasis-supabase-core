-- GFT-100: configurable retail commerce contract and fail-closed validation.
--
-- STATUS: PENDING OWNER APPROVAL. NOT ACTIVATED. This migration builds configuration infrastructure
-- only. It sets no value, approves nothing, computes no price and creates no order or payment. The
-- proposed architecture (one governed B2C order surface in Core, shared with the Customer App) stays a
-- proposal until `architecture_approved` is approved by an administrator with a recorded reference AND
-- `activation_enabled` is separately approved. Every commercial action stays blocked while any setting
-- it depends on is missing, merely proposed, or invalid.
--
-- Stacked on 20261118220000_gifting_enquiry_staff_queue_v1.sql (uses public.is_admin()).

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- -----------------------------------------------------------------------------
-- 1. Catalogue of known settings (types and ranges only; never business values)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_commerce_setting_catalogue_v1()
RETURNS TABLE (setting_key text, value_type text, constraint_spec jsonb, description text)
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT * FROM (VALUES
    ('architecture_approved',            'boolean', '{}'::jsonb,                                  'Owner approval of the proposed retail commerce architecture'),
    ('activation_enabled',              'boolean', '{}'::jsonb,                                  'Separate activation switch; requires architecture_approved'),
    ('payment.provider',                'enum',    '{"values":["razorpay","cashfree","payu","stripe"]}', 'Payment provider (Core payment intents already model these codes)'),
    ('payment.settlement_account_ref',  'string',  '{"min":3,"max":80}',                          'Reference to the settlement account record, never account numbers'),
    ('tax.price_display_mode',          'enum',    '{"values":["inclusive","exclusive"]}',        'Whether displayed prices include GST'),
    ('tax.seller_state_code',           'string',  '{"pattern":"^[0-9]{2}$"}',                    'Two-digit GST state code of the supplying entity (intra/inter-state rule)'),
    ('shipping.model',                  'enum',    '{"values":["flat","slab","free_above"]}',     'Shipping charge model'),
    ('shipping.fee_table_ref',          'string',  '{"min":3,"max":80}',                          'Reference to the approved rate card version'),
    ('shipping.serviceable_pin_policy_ref','string','{"min":3,"max":80}',                         'Reference to the approved serviceable PIN list version'),
    ('shipping.free_above_amount_inr',  'number',  '{"min":0,"max":1000000}',                     'Order value above which shipping is free (only when model = free_above)'),
    ('shipping.delivery_promise_days',  'integer', '{"min":1,"max":30}',                          'Delivery promise in working days'),
    ('refund.window_hours',             'integer', '{"min":0,"max":720}',                         'Hours after delivery within which damage/incorrect items may be reported'),
    ('refund.method',                   'enum',    '{"values":["original_payment"]}',             'How approved refunds are paid'),
    ('refund.approver_role',            'enum',    '{"values":["finance","admin","super_admin"]}','Role that approves refunds'),
    ('refund.perishable_policy_ref',    'string',  '{"min":3,"max":80}',                          'Reference to the approved perishable-goods refund rules'),
    ('checkout.guest_allowed',          'boolean', '{}'::jsonb,                                  'Whether checkout without an account is allowed'),
    ('quote.validity_minutes',          'integer', '{"min":1,"max":120}',                         'How long a quote stays valid'),
    ('stock.reservation_minutes',       'integer', '{"min":1,"max":180}',                         'How long stock is reserved for an accepted quote')
  ) AS t(setting_key, value_type, constraint_spec, description);
$$;

-- Which settings each commercial action depends on.
CREATE OR REPLACE FUNCTION public.retail_commerce_action_requirements_v1()
RETURNS TABLE (action text, setting_key text)
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  WITH gates(k) AS (VALUES ('architecture_approved'), ('activation_enabled')),
  quote_keys(k) AS (VALUES
    ('tax.price_display_mode'), ('tax.seller_state_code'), ('shipping.model'), ('shipping.fee_table_ref'),
    ('shipping.serviceable_pin_policy_ref'), ('shipping.delivery_promise_days'),
    ('quote.validity_minutes'), ('stock.reservation_minutes')),
  order_keys(k) AS (SELECT k FROM quote_keys UNION ALL SELECT 'checkout.guest_allowed'),
  payment_keys(k) AS (SELECT k FROM order_keys UNION ALL VALUES ('payment.provider'), ('payment.settlement_account_ref')),
  refund_keys(k) AS (VALUES ('payment.provider'), ('refund.window_hours'), ('refund.method'),
    ('refund.approver_role'), ('refund.perishable_policy_ref'))
  SELECT 'quote', k FROM (SELECT k FROM gates UNION ALL SELECT k FROM quote_keys) q
  UNION ALL SELECT 'order', k FROM (SELECT k FROM gates UNION ALL SELECT k FROM order_keys) o
  UNION ALL SELECT 'payment', k FROM (SELECT k FROM gates UNION ALL SELECT k FROM payment_keys) p
  UNION ALL SELECT 'refund', k FROM (SELECT k FROM gates UNION ALL SELECT k FROM refund_keys) r;
$$;

-- Type/range validation only.
CREATE OR REPLACE FUNCTION public.retail_commerce_validate_value_v1(p_key text, p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  c record;
  v_num numeric;
BEGIN
  SELECT * INTO c FROM public.retail_commerce_setting_catalogue_v1() k WHERE k.setting_key = p_key;
  IF NOT FOUND OR p_value IS NULL THEN
    RETURN false;
  END IF;

  CASE c.value_type
    WHEN 'boolean' THEN
      RETURN jsonb_typeof(p_value) = 'boolean';
    WHEN 'enum' THEN
      RETURN jsonb_typeof(p_value) = 'string'
        AND (p_value #>> '{}') IN (SELECT jsonb_array_elements_text(c.constraint_spec -> 'values'));
    WHEN 'string' THEN
      IF jsonb_typeof(p_value) <> 'string' THEN RETURN false; END IF;
      IF c.constraint_spec ? 'pattern' THEN
        RETURN (p_value #>> '{}') ~ (c.constraint_spec ->> 'pattern');
      END IF;
      RETURN char_length(p_value #>> '{}') BETWEEN (c.constraint_spec ->> 'min')::int AND (c.constraint_spec ->> 'max')::int;
    WHEN 'integer', 'number' THEN
      IF jsonb_typeof(p_value) <> 'number' THEN RETURN false; END IF;
      v_num := (p_value #>> '{}')::numeric;
      IF c.value_type = 'integer' AND v_num <> trunc(v_num) THEN RETURN false; END IF;
      RETURN v_num BETWEEN (c.constraint_spec ->> 'min')::numeric AND (c.constraint_spec ->> 'max')::numeric;
    ELSE
      RETURN false;
  END CASE;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. Storage: nobody writes directly; the validating setter is the only path
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.retail_commerce_settings (
  setting_key text PRIMARY KEY,
  value jsonb NOT NULL,
  status text NOT NULL DEFAULT 'proposed',
  approval_reference text,
  approved_by uuid,
  approved_at timestamptz,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT retail_commerce_settings_status_check CHECK (status IN ('proposed', 'approved')),
  CONSTRAINT retail_commerce_settings_approved_evidence CHECK (
    status <> 'approved'
    OR (nullif(btrim(approval_reference), '') IS NOT NULL AND approved_by IS NOT NULL AND approved_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.retail_commerce_setting_history (
  id bigserial PRIMARY KEY,
  setting_key text NOT NULL,
  old_value jsonb,
  new_value jsonb NOT NULL,
  old_status text,
  new_status text NOT NULL,
  approval_reference text,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.retail_commerce_settings IS
  'PENDING OWNER APPROVAL. Retail commerce configuration. Writable only through retail_commerce_set_setting_v1 (admin). Approved rows require an approval reference.';
COMMENT ON TABLE public.retail_commerce_setting_history IS
  'Append-only change history of retail commerce settings.';

ALTER TABLE public.retail_commerce_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_commerce_setting_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.retail_commerce_settings FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.retail_commerce_setting_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.retail_commerce_settings TO service_role;
GRANT SELECT ON TABLE public.retail_commerce_setting_history TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Admin setter: validates, requires evidence to approve, records history
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_commerce_set_setting_v1(
  p_key text,
  p_value jsonb,
  p_status text DEFAULT 'proposed',
  p_approval_reference text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_old public.retail_commerce_settings%ROWTYPE;
  v_reference text := nullif(btrim(coalesce(p_approval_reference, '')), '');
BEGIN
  -- Only an authenticated, active administrator; service_role and automation can never write or approve.
  IF v_actor IS NULL OR NOT coalesce(public.is_admin(), false) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('proposed', 'approved') THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  IF NOT public.retail_commerce_validate_value_v1(p_key, p_value) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'approved' AND v_reference IS NULL THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_APPROVAL_REFERENCE_REQUIRED' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_old FROM public.retail_commerce_settings WHERE setting_key = p_key FOR UPDATE;

  INSERT INTO public.retail_commerce_settings AS s (
    setting_key, value, status, approval_reference, approved_by, approved_at, updated_by, updated_at
  ) VALUES (
    p_key, p_value, p_status,
    CASE WHEN p_status = 'approved' THEN v_reference END,
    CASE WHEN p_status = 'approved' THEN v_actor END,
    CASE WHEN p_status = 'approved' THEN now() END,
    v_actor, now()
  )
  ON CONFLICT (setting_key) DO UPDATE
     SET value = EXCLUDED.value,
         status = EXCLUDED.status,
         approval_reference = EXCLUDED.approval_reference,
         approved_by = EXCLUDED.approved_by,
         approved_at = EXCLUDED.approved_at,
         updated_by = EXCLUDED.updated_by,
         updated_at = EXCLUDED.updated_at;

  INSERT INTO public.retail_commerce_setting_history (
    setting_key, old_value, new_value, old_status, new_status, approval_reference, changed_by
  ) VALUES (
    p_key, v_old.value, p_value, v_old.status, p_status, v_reference, v_actor
  );

  RETURN jsonb_build_object('key', p_key, 'status', p_status);
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Readiness: which actions are allowed, and exactly what blocks the rest
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_commerce_readiness_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actions jsonb := '{}'::jsonb;
  v_action text;
  v_missing text[];
  v_unapproved text[];
  v_invalid text[];
  v_model text;
  v_quote_validity numeric;
  v_reservation numeric;
  v_arch boolean;
  v_active boolean;
BEGIN
  SELECT (value #>> '{}')::boolean INTO v_arch
    FROM public.retail_commerce_settings
   WHERE setting_key = 'architecture_approved' AND status = 'approved';
  SELECT (value #>> '{}')::boolean INTO v_active
    FROM public.retail_commerce_settings
   WHERE setting_key = 'activation_enabled' AND status = 'approved';

  SELECT value #>> '{}' INTO v_model FROM public.retail_commerce_settings
   WHERE setting_key = 'shipping.model' AND status = 'approved';
  SELECT (value #>> '{}')::numeric INTO v_quote_validity FROM public.retail_commerce_settings
   WHERE setting_key = 'quote.validity_minutes' AND status = 'approved';
  SELECT (value #>> '{}')::numeric INTO v_reservation FROM public.retail_commerce_settings
   WHERE setting_key = 'stock.reservation_minutes' AND status = 'approved';

  FOR v_action IN SELECT DISTINCT r.action FROM public.retail_commerce_action_requirements_v1() r ORDER BY 1 LOOP
    WITH required AS (
      SELECT r.setting_key AS k FROM public.retail_commerce_action_requirements_v1() r WHERE r.action = v_action
      UNION
      SELECT 'shipping.free_above_amount_inr'
       WHERE v_action IN ('quote', 'order', 'payment') AND v_model = 'free_above'
    )
    SELECT
      coalesce(array_agg(q.k ORDER BY q.k) FILTER (WHERE s.setting_key IS NULL), ARRAY[]::text[]),
      coalesce(array_agg(q.k ORDER BY q.k) FILTER (WHERE s.setting_key IS NOT NULL AND s.status <> 'approved'), ARRAY[]::text[]),
      coalesce(array_agg(q.k ORDER BY q.k) FILTER (
        WHERE s.setting_key IS NOT NULL AND s.status = 'approved'
          AND (NOT public.retail_commerce_validate_value_v1(q.k, s.value)
               OR (q.k IN ('architecture_approved', 'activation_enabled') AND s.value <> 'true'::jsonb))), ARRAY[]::text[])
      INTO v_missing, v_unapproved, v_invalid
      FROM required q LEFT JOIN public.retail_commerce_settings s ON s.setting_key = q.k;

    -- Cross-field rule: stock must be held at least as long as the quote is valid.
    IF v_action IN ('quote', 'order', 'payment')
       AND v_quote_validity IS NOT NULL AND v_reservation IS NOT NULL AND v_reservation < v_quote_validity THEN
      v_invalid := v_invalid || ARRAY['stock.reservation_minutes<quote.validity_minutes'];
    END IF;
    -- Activation can never be effective without the architecture approval.
    IF coalesce(v_active, false) AND NOT coalesce(v_arch, false) AND NOT ('activation_enabled' = ANY (v_invalid)) THEN
      v_invalid := v_invalid || ARRAY['activation_enabled_without_architecture_approved'];
    END IF;

    v_actions := v_actions || jsonb_build_object(v_action, jsonb_build_object(
      'allowed', cardinality(v_missing) = 0 AND cardinality(v_unapproved) = 0 AND cardinality(v_invalid) = 0,
      'missing', to_jsonb(v_missing),
      'unapproved', to_jsonb(v_unapproved),
      'invalid', to_jsonb(v_invalid)
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'contractVersion', 1,
    'architectureStatus', CASE WHEN coalesce(v_arch, false) THEN 'approved' ELSE 'pending_owner_approval' END,
    'activated', coalesce(v_arch, false) AND coalesce(v_active, false),
    'actions', v_actions,
    'evaluatedAt', to_jsonb(now())
  );
END;
$$;

-- Fail-closed guard future commercial functions must call first.
CREATE OR REPLACE FUNCTION public.retail_commerce_assert_action_v1(p_action text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_readiness jsonb := public.retail_commerce_readiness_v1();
  v_entry jsonb := v_readiness -> 'actions' -> p_action;
BEGIN
  IF v_entry IS NULL THEN
    RAISE EXCEPTION 'RETAIL_COMMERCE_INVALID_ACTION' USING ERRCODE = '22023';
  END IF;
  IF NOT coalesce((v_entry ->> 'allowed')::boolean, false) THEN
    RAISE EXCEPTION 'RETAIL_COMMERCE_BLOCKED' USING ERRCODE = 'P0001', DETAIL = v_entry::text;
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Request validation and a quote entry point that can never return a quote yet
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_quote_request_validate_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_item jsonb;
  v_ship jsonb;
  v_key text;
  v_items jsonb := '[]'::jsonb;
  v_qty numeric;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request) <> 'object' OR octet_length(p_request::text) > 32768 THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_request) LOOP
    IF v_key NOT IN ('idempotencyKey', 'items', 'shipTo', 'currency', 'giftMessage') THEN
      RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF jsonb_typeof(p_request -> 'idempotencyKey') IS DISTINCT FROM 'string'
     OR (p_request ->> 'idempotencyKey') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR coalesce(p_request ->> 'currency', 'INR') <> 'INR'
     OR (p_request ? 'giftMessage' AND (jsonb_typeof(p_request -> 'giftMessage') <> 'string'
                                         OR char_length(p_request ->> 'giftMessage') > 500)) THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_request -> 'items') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_request -> 'items') NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_request -> 'items') LOOP
    IF jsonb_typeof(v_item) <> 'object'
       OR jsonb_typeof(v_item -> 'productId') IS DISTINCT FROM 'string'
       OR (v_item ->> 'productId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR jsonb_typeof(v_item -> 'quantity') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
    END IF;
    v_qty := (v_item ->> 'quantity')::numeric;
    IF v_qty <> trunc(v_qty) OR v_qty NOT BETWEEN 1 AND 99 THEN
      RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
    END IF;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'productId', lower(v_item ->> 'productId'), 'quantity', v_qty::int));
  END LOOP;

  v_ship := p_request -> 'shipTo';
  IF jsonb_typeof(v_ship) IS DISTINCT FROM 'object'
     OR coalesce(v_ship ->> 'pincode', '') !~ '^[1-9][0-9]{5}$'
     OR coalesce(v_ship ->> 'stateCode', '') !~ '^[0-9]{2}$' THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'idempotencyKey', lower(p_request ->> 'idempotencyKey'),
    'items', v_items,
    'shipTo', jsonb_build_object('pincode', v_ship ->> 'pincode', 'stateCode', v_ship ->> 'stateCode'),
    'currency', 'INR'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.retail_quote_create_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM public.retail_quote_request_validate_v1(p_request);
  PERFORM public.retail_commerce_assert_action_v1('quote');
  -- Even with every setting approved, no quote is produced until the pricing engine is built and
  -- approved. This function exists so callers integrate against the fail-closed contract now.
  RAISE EXCEPTION 'RETAIL_QUOTE_NOT_IMPLEMENTED' USING ERRCODE = '0A000';
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Privileges
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.retail_commerce_setting_catalogue_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_commerce_action_requirements_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_commerce_validate_value_v1(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_commerce_set_setting_v1(text, jsonb, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retail_commerce_readiness_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retail_commerce_assert_action_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_quote_request_validate_v1(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_quote_create_v1(jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.retail_commerce_setting_catalogue_v1() TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_commerce_action_requirements_v1() TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_commerce_validate_value_v1(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_commerce_set_setting_v1(text, jsonb, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.retail_commerce_readiness_v1() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.retail_commerce_assert_action_v1(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_quote_request_validate_v1(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_quote_create_v1(jsonb) TO service_role;
