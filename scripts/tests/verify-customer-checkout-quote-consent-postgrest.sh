#!/usr/bin/env bash
# Local-only PostgREST RPC verification for Core #488 quote-consent ACL barrier.
# Fails closed unless the API URL resolves to loopback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if ! supabase status >/dev/null 2>&1; then
  echo "POSTGREST_VERIFY: local Supabase stack is not running" >&2
  exit 1
fi

STATUS_JSON="$(supabase status -o json 2>/dev/null)"
API_URL="$(python3 -c "import json,sys; print(json.load(sys.stdin)['API_URL'])" <<<"$STATUS_JSON")"
ANON_KEY="$(python3 -c "import json,sys; print(json.load(sys.stdin)['ANON_KEY'])" <<<"$STATUS_JSON")"
DB_URL="$(python3 -c "import json,sys; print(json.load(sys.stdin)['DB_URL'])" <<<"$STATUS_JSON")"

case "$API_URL" in
  http://127.0.0.1:*|http://localhost:* ) ;;
  * )
    echo "POSTGREST_VERIFY: refusing non-local API_URL=$API_URL" >&2
    exit 1
    ;;
esac

PREFIX="p488-pr-$(date +%s)-$RANDOM"
BUYER_EMAIL="${PREFIX}@example.invalid"
PASS="${PREFIX}Aa1!"

# A private, unpredictable temporary file prevents symlink overwrite and leaves no
# synthetic signup response behind after this local-only verification run.
SIGNUP_FILE="$(mktemp "${TMPDIR:-/tmp}/p488-signup.XXXXXXXX")"
trap 'rm -f -- "$SIGNUP_FILE"' EXIT

SIGNUP_CODE="$(curl -sS -o "$SIGNUP_FILE" -w "%{http_code}" -X POST "$API_URL/auth/v1/signup" \
  -H "apikey: $ANON_KEY" \
  -H "content-type: application/json" \
  -d "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASS\"}")"
if [[ "$SIGNUP_CODE" != "200" && "$SIGNUP_CODE" != "201" ]]; then
  echo "POSTGREST_VERIFY: signup failed HTTP $SIGNUP_CODE" >&2
  # A signup response may contain tokens; do not print it to CI logs.
  exit 1
fi

BUYER_ID="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user',{}).get('id') or d.get('id') or '')" "$SIGNUP_FILE")"
if [[ -z "$BUYER_ID" ]]; then
  echo "POSTGREST_VERIFY: signup response missing buyer id" >&2
  exit 1
fi
TOKEN="$(curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" \
  -H "content-type: application/json" \
  -d "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASS\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")"

FIXTURE_JSON="$(python3 - "$DB_URL" "$PREFIX" "$BUYER_EMAIL" "$BUYER_ID" <<'PY'
import json, subprocess, sys, uuid
db_url, prefix, email, buyer = sys.argv[1:5]
company = str(uuid.uuid4())
product = str(uuid.uuid4())
sql = f"""
SET session_replication_role = replica;
INSERT INTO public.companies (id, business_name, status) VALUES ('{company}', 'P488 PostgREST Co', 'active');
UPDATE public.users
  SET company_id = '{company}', role = 'b2b_buyer'
  WHERE id = '{buyer}';
INSERT INTO public.profiles (id, company_id, role, is_approved, status, email)
  VALUES ('{buyer}', '{company}', 'b2b_buyer', true, 'approved', '{email}')
  ON CONFLICT (id) DO UPDATE SET
    company_id = EXCLUDED.company_id,
    role = EXCLUDED.role,
    is_approved = EXCLUDED.is_approved,
    status = EXCLUDED.status,
    email = EXCLUDED.email;
INSERT INTO public.products (
  id, sku, product_name, name, category, hsn_code,
  is_active, visible_in_catalog, is_catalogue_ready,
  moq_value, increment_value, base_price, price_b2b
) VALUES (
  '{product}', 'P488-SKU-{prefix}', 'P488 Product', 'P488 Product', 'Bakery', '19059090',
  true, true, true, 1, 1, 200, 200
);
INSERT INTO public.product_pricing_rules (
  product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
) VALUES ('{product}', 'b2b', 'approved', 200, 200, 'INR', 'kg', 0, true);
INSERT INTO public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  VALUES ('{product}', 'b2b', true, 1, 1, 1);
SET session_replication_role = DEFAULT;
"""
subprocess.check_call(
    ["psql", db_url, "-v", "ON_ERROR_STOP=1", "-q", "-c", sql],
    stdout=subprocess.DEVNULL,
)
print(json.dumps({"product_id": product}))
PY
)"
PRODUCT_ID="$(python3 -c "import json,sys; print(json.load(sys.stdin)['product_id'])" <<<"$FIXTURE_JSON")"

rpc() {
  local name="$1" body="$2"
  curl -sS -w "\n%{http_code}" -X POST "$API_URL/rest/v1/rpc/$name" \
    -H "apikey: $ANON_KEY" \
    -H "authorization: Bearer $TOKEN" \
    -H "content-type: application/json" \
    -d "$body"
}

ADD_LINE="$(rpc add_customer_order_draft_line_v1 "{\"p_product_id\":\"$PRODUCT_ID\",\"p_quantity\":1}")"
ADD_CODE="$(echo "$ADD_LINE" | tail -n 1)"
if [[ "$ADD_CODE" != "200" && "$ADD_CODE" != "204" ]]; then
  echo "POSTGREST_VERIFY: add line failed HTTP $ADD_CODE body=$(echo "$ADD_LINE" | head -n -1)" >&2
  exit 1
fi

LEGACY="$(rpc submit_customer_order_v1 "{\"p_idempotency_key\":\"$PREFIX-legacy\",\"p_requested_dispatch_date\":null}")"
LEGACY_CODE="$(echo "$LEGACY" | tail -n 1)"
if [[ "$LEGACY_CODE" != "403" ]]; then
  echo "POSTGREST_VERIFY: legacy submit expected HTTP 403, got $LEGACY_CODE" >&2
  exit 1
fi

QUOTE="$(rpc customer_checkout_quote_v1 '{}')"
QUOTE_CODE="$(echo "$QUOTE" | tail -n 1)"
QUOTE_BODY="$(echo "$QUOTE" | head -n -1)"
if [[ "$QUOTE_CODE" != "200" ]]; then
  echo "POSTGREST_VERIFY: quote failed HTTP $QUOTE_CODE body=$QUOTE_BODY" >&2
  exit 1
fi
FP="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['fingerprint'])" "$QUOTE_BODY")"

QUOTED="$(rpc submit_customer_order_quoted_v1 "{\"p_idempotency_key\":\"$PREFIX-quoted\",\"p_quote_fingerprint\":\"$FP\",\"p_requested_dispatch_date\":null}")"
QUOTED_CODE="$(echo "$QUOTED" | tail -n 1)"
if [[ "$QUOTED_CODE" != "200" ]]; then
  echo "POSTGREST_VERIFY: quoted submit failed HTTP $QUOTED_CODE body=$(echo "$QUOTED" | head -n -1)" >&2
  exit 1
fi

ORDER_COUNT="$(psql "$DB_URL" -qAt -c "select count(*)::text from public.orders where checkout_idempotency_key='$PREFIX-quoted'")"
if [[ "$ORDER_COUNT" != "1" ]]; then
  echo "POSTGREST_VERIFY: expected exactly one order row, got $ORDER_COUNT" >&2
  exit 1
fi

echo "POSTGREST_VERIFY: PASS legacy_denied_http=$LEGACY_CODE quoted_ok_http=$QUOTED_CODE order_rows=$ORDER_COUNT"
