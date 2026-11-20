// LOCAL sandbox acceptance for the retail checkout: the real edge handlers (retail-checkout, razorpay-webhook)
// against a real PostgreSQL that has the Core migrations applied, with MSG91 and Razorpay replaced by local fakes.
//
//   RETAIL_E2E_DB_URL=postgresql://user@127.0.0.1:5432/scratch deno run -A scripts/uat/retail-checkout-local-sandbox-e2e.ts
//
// Safety: refuses any database host other than localhost/127.0.0.1/a unix socket, writes only SYNTHETIC test settings
// (approval reference LOCAL-E2E-SYNTHETIC) and synthetic products, and never contacts MSG91, Razorpay or Supabase.
// This is NOT hosted acceptance and NOT a Razorpay sandbox run: it proves the integration logic end to end locally.

import postgres from "npm:postgres@3.4.4";
import { handleRetailCheckoutRequest, type CheckoutDeps } from "../../supabase/functions/_shared/retailCheckout.ts";
import { handleRazorpayWebhook, razorpaySignature } from "../../supabase/functions/_shared/razorpayWebhook.ts";

const url = Deno.env.get("RETAIL_E2E_DB_URL") ?? "";
const host = (() => { try { return new URL(url).hostname; } catch { return ""; } })();
if (!url || !["localhost", "127.0.0.1", ""].includes(host) && !host.startsWith("/")) {
  console.error("REFUSED: RETAIL_E2E_DB_URL must point at a local scratch database");
  Deno.exit(2);
}
const sql = postgres(url, { max: 1, onnotice: () => {} });
const results: Array<[boolean, string]> = [];
const check = (ok: boolean, name: string, detail = "") => { results.push([ok, name]); console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : ` ${detail}`}`); };

const ADMIN = "96000000-0000-0000-0000-0000000000a1";
const P_A = "96100000-0000-0000-0000-00000000000a";
const P_B = "96100000-0000-0000-0000-00000000000b";
const WEBHOOK_SECRET = "local-e2e-webhook-secret";
const uuid = () => crypto.randomUUID();

// --- synthetic fixtures + synthetic settings (clearly labelled; test database only) -------------------------------
await sql.begin(async (tx) => {
  await tx`insert into auth.users (id, email) values (${ADMIN}, 'e2e-admin@example.invalid') on conflict do nothing`;
  await tx`insert into public.users (id, role, email, is_active) values (${ADMIN}, 'admin', 'e2e-admin@example.invalid', true) on conflict do nothing`;
  for (const [id, sku, hsn, gst] of [[P_A, "E2E-A", "1704.90.90", 5], [P_B, "E2E-B", "1806.90.90", 18]] as const) {
    await tx`insert into public.products (id, name, sku, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, gst_percentage, gst_rate)
             values (${id}, ${"E2E " + sku}, ${sku}, 'ready_goods', ${hsn}, true, true, true, ${gst}, ${gst}) on conflict (id) do nothing`;
    await tx`insert into public.product_pricing_rules (product_id, price_channel, base_price, gst_rate, tax_inclusive, approval_status, approved_at)
             values (${id}, 'retail', ${gst === 5 ? 105 : 118}, ${gst}, true, 'approved', now()) on conflict (product_id, price_channel) do nothing`;
  }
  await tx`select set_config('request.jwt.claim.sub', ${ADMIN}, true)`;
  const settings: Array<[string, unknown]> = [
    ["checkout.guest_allowed", true], ["tax.price_display_mode", "inclusive"], ["tax.seller_state_code", "07"],
    ["shipping.model", "slab"], ["shipping.fee_table_ref", "LOCAL-E2E-RATECARD"], ["shipping.serviceable_pin_policy_ref", "LOCAL-E2E-PINS"],
    ["shipping.delivery_promise_days", 5], ["quote.validity_minutes", 15], ["stock.reservation_minutes", 30],
    ["payment.provider", "razorpay"], ["payment.settlement_account_ref", "LOCAL-E2E-SETTLEMENT"],
    ["architecture_approved", true], ["activation_enabled", true],
  ];
  for (const [k, v] of settings) await tx`select public.retail_commerce_set_setting_v1(${k}, ${tx.json(v as never)}, 'approved', 'LOCAL-E2E-SYNTHETIC')`;
  await tx`select public.retail_serviceable_pincodes_replace_v1('LOCAL-E2E-PINS', array['110015'])`;
  await tx`select public.retail_shipping_rate_card_replace_v1('LOCAL-E2E-RATECARD',
    '[{"minSubtotalInr":0,"belowSubtotalInr":500,"feeInr":59,"gstRatePercent":18},{"minSubtotalInr":500,"belowSubtotalInr":null,"feeInr":0,"gstRatePercent":18}]'::jsonb)`;
});

// --- local fakes for the two external providers -----------------------------------------------------------------
let razorpayOrders = 0;
const deps: CheckoutDeps = {
  rpc: async (name, args) => {
    try {
      const keys = Object.keys(args);
      // postgres.js serialises jsonb parameters itself; pass objects as they are.
      const values = keys.map((k) => args[k]);
      const casts: Record<string, string> = { p_request: "::jsonb", p_payload: "::jsonb", p_quote_id: "::uuid", p_order_id: "::uuid", p_intent_id: "::uuid", p_product_ids: "::uuid[]" };
      const call = `select public.${name}(${keys.map((k, i) => `$${i + 1}${casts[k] ?? ""}`).join(", ")}) as r`;
      const rows = await sql.unsafe(call, values as never);
      return { data: rows[0]?.r ?? null, error: null };
    } catch (e) {
      const err = e as { message?: string; code?: string; detail?: string };
      return { data: null, error: { message: err.message, code: err.code, details: err.detail } };
    }
  },
  verifyPhone: (token) => Promise.resolve(token === "fake-msg91-ok" ? { ok: true, phone: "919810012345" } : { ok: false }),
  razorpay: { keyId: "rzp_test_local", create: (i) => { razorpayOrders++; return Promise.resolve({ ok: true, orderId: "order_LocalE2E" + String(razorpayOrders).padStart(6, "0") }); } },
  allowedOrigins: [],
};
const call = async (route: string, body: unknown, token?: string) => {
  const res = await handleRetailCheckoutRequest(new Request(`https://local.invalid/functions/v1/retail-checkout/${route}`, {
    method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body),
  }), deps);
  return { status: res.status, body: await res.json() as Record<string, any> };
};
const webhook = async (raw: string, eventId: string, secret = WEBHOOK_SECRET) => {
  const res = await handleRazorpayWebhook(new Request("https://local.invalid/functions/v1/razorpay-webhook", {
    method: "POST", headers: { "x-razorpay-signature": await razorpaySignature(raw, secret), "x-razorpay-event-id": eventId }, body: raw,
  }), {
    secret: WEBHOOK_SECRET,
    apply: async (args) => {
      try {
        const r = await sql`select public.retail_payment_event_apply_v1(${args.p_provider_event_id as string}, ${args.p_event_type as string}, ${args.p_provider_order_id as string},
          ${args.p_provider_payment_id as string}, ${args.p_amount_paise as number}, ${args.p_currency as string}, ${sql.json(args.p_payload as never)}, ${args.p_payload_hash as string}) as r`;
        return { data: r[0]!.r, error: null };
      } catch (e) { return { data: null, error: { message: (e as Error).message } }; }
    },
    reject: async (h, reason) => { await sql`select public.retail_payment_event_reject_v1(${h}, ${reason})`; },
  });
  return { status: res.status, body: await res.json() as Record<string, any> };
};

// --- the journey ------------------------------------------------------------------------------------------------
const bad = await call("session", { accessToken: "wrong" });
check(bad.status === 401, "an unverified phone gets no session");
const sess = await call("session", { accessToken: "fake-msg91-ok" });
check(sess.status === 201 && /^rsess_[0-9a-f]{64}$/.test(sess.body.sessionToken), "a verified phone gets a guest session");
const token = sess.body.sessionToken as string;

const display = await call("price-display", { productIds: [P_A, P_B] });
check(display.status === 200 && display.body.items[0].taxIncludedPerUnit === 5 && display.body.items[1].taxIncludedPerUnit === 18, "GST-inclusive display shows included tax per unit", JSON.stringify(display.body));

const qKey = uuid();
const quoteReq = { idempotencyKey: qKey, items: [{ productId: P_A, quantity: 2 }, { productId: P_B, quantity: 1 }], shipTo: { pincode: "110015", stateCode: "07" }, currency: "INR" };
const quote = await call("quote", quoteReq, token);
check(quote.status === 201 && quote.body.totals.inclusiveTotal === 387 && quote.body.totals.taxTotal === 37, "quote: GST-inclusive total 387.00 with 37.00 tax", JSON.stringify(quote));
check((await call("quote", quoteReq, token)).status === 200, "quote replay is idempotent");
check((await call("quote", { ...quoteReq, items: [{ productId: P_A, quantity: 9 }] }, token)).status === 409, "same key, different request conflicts");
check((await call("quote", { ...quoteReq, idempotencyKey: uuid(), shipTo: { pincode: "560001", stateCode: "29" } }, token)).body.error === "pin_not_serviceable", "unserviceable PIN is refused");

const order = await call("order", { quoteId: quote.body.quoteId, idempotencyKey: uuid() }, token);
check(order.status === 201 && order.body.status === "pending_payment" && order.body.stockReservationEnforced === false, "order created, pending payment, reservation not inventory-enforced");

const other = await call("session", { accessToken: "fake-msg91-ok" });
check((await call("order", { quoteId: quote.body.quoteId, idempotencyKey: uuid() }, other.body.sessionToken)).status === 409, "a second order from the same quote is refused (same customer, new session)");
await sql`insert into public.retail_customers (phone_e164, phone_verified_at) values ('919810099999', now()) on conflict do nothing`;
const stranger = (await sql`select public.retail_session_issue_v1('919810099999') as r`)[0]!.r as { sessionToken: string };
check((await call("payment-intent", { orderId: order.body.orderId }, stranger.sessionToken)).status === 404, "another customer cannot pay my order and cannot tell it exists");

const pay = await call("payment-intent", { orderId: order.body.orderId }, token);
check(pay.status === 201 && pay.body.amountPaise === 38700 && pay.body.razorpayOrderId.startsWith("order_LocalE2E"), "payment intent: server-derived amount in paise, Razorpay (fake) order associated");
const pay2 = await call("payment-intent", { orderId: order.body.orderId }, token);
check(pay2.status === 200 && pay2.body.razorpayOrderId === pay.body.razorpayOrderId && razorpayOrders === 1, "payment intent is idempotent and does not create a second provider order");

const evt = (id: string, amount: number, type = "payment.captured") =>
  JSON.stringify({ event: type, payload: { payment: { entity: { id, order_id: pay.body.razorpayOrderId, amount, currency: "INR" } } } });
const tamper = await webhook(evt("pay_E2E1", 38700), "evt_e2e_bad", "not-the-secret");
check(tamper.status === 401, "a webhook signed with the wrong secret is rejected");
check(Number((await sql`select count(*)::int c from public.retail_payment_event_rejections`)[0]!.c) >= 1, "…and the rejection is logged durably");
const wrongAmount = await webhook(evt("pay_E2E0", 100), "evt_e2e_mismatch");
check(wrongAmount.status === 200 && wrongAmount.body.outcome === "amount_mismatch", "a signed event with the wrong amount is recorded as a mismatch");
check((await sql`select status from public.retail_orders where id = ${order.body.orderId}`)[0]!.status === "pending_payment", "…and does not pay the order");
const good = await webhook(evt("pay_E2E1", 38700), "evt_e2e_ok");
check(good.status === 200 && good.body.outcome === "applied", "a signed matching capture is applied");
check((await sql`select status from public.retail_orders where id = ${order.body.orderId}`)[0]!.status === "paid", "…and the order is paid");
const again = await webhook(evt("pay_E2E1", 38700), "evt_e2e_ok");
check(again.status === 200, "a redelivered event is acknowledged");
check(Number((await sql`select count(*)::int c from public.retail_payment_events where provider_event_id = 'evt_e2e_ok'`)[0]!.c) === 1, "…and stored exactly once");
check((await call("payment-intent", { orderId: order.body.orderId }, token)).status === 409, "a paid order cannot be paid again");

await sql.end();
const failed = results.filter(([ok]) => !ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed (LOCAL, fakes for MSG91 and Razorpay; not hosted acceptance)`);
Deno.exit(failed ? 1 : 0);
