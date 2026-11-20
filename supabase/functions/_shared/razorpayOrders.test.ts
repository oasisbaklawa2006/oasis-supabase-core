import { createRazorpayOrder, RAZORPAY_ORDERS_URL, sandboxConfig } from "./razorpayOrders.ts";

function eq(a: unknown, b: unknown, m = ""): void {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m || "values differ"}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
const CFG = { keyId: "rzp_test_abc", keySecret: "secret" };
const INPUT = { amountPaise: 38700, currency: "INR" as const, receipt: "intent-1", notes: { intent: "intent-1" } };
const reply = (body: unknown, status = 200) => () => Promise.resolve(new Response(JSON.stringify(body), { status }));

Deno.test("live keys are refused everywhere; test keys are accepted; absent keys are 'not configured'", () => {
  eq(sandboxConfig("rzp_live_abc", "s"), { ok: false, reason: "live_keys_refused" });
  eq(sandboxConfig(undefined, "s"), { ok: false, reason: "not_configured" });
  eq(sandboxConfig("rzp_test_abc", ""), { ok: false, reason: "not_configured" });
  eq(sandboxConfig("rzp_test_abc", "s").ok, true);
});

Deno.test("a live key can never create an order, even if configuration is bypassed", async () => {
  let called = false;
  const res = await createRazorpayOrder({ keyId: "rzp_live_abc", keySecret: "s" }, INPUT, () => {
    called = true;
    return Promise.resolve(new Response("{}"));
  });
  eq(res, { ok: false, reason: "live_keys_refused" });
  eq(called, false);
});

Deno.test("the request carries paise, INR, receipt and basic auth; a matching response yields the order id", async () => {
  let seen: { url: string; init: RequestInit } | null = null;
  const res = await createRazorpayOrder(CFG, INPUT, (url, init) => {
    seen = { url: String(url), init: init! };
    return Promise.resolve(new Response(JSON.stringify({ id: "order_TESTAAAA0001", amount: 38700, currency: "INR" })));
  });
  eq(res, { ok: true, orderId: "order_TESTAAAA0001" });
  eq(seen!.url, RAZORPAY_ORDERS_URL);
  eq(JSON.parse(String(seen!.init.body)), { amount: 38700, currency: "INR", receipt: "intent-1", notes: { intent: "intent-1" } });
  eq((seen!.init.headers as Record<string, string>).authorization, `Basic ${btoa("rzp_test_abc:secret")}`);
});

Deno.test("an echo that does not match what we asked for is rejected", async () => {
  for (const body of [{ id: "order_TESTAAAA0001", amount: 100, currency: "INR" }, { id: "bad id", amount: 38700, currency: "INR" },
    { id: "order_TESTAAAA0001", amount: 38700, currency: "USD" }, null]) {
    eq(await createRazorpayOrder(CFG, INPUT, reply(body)), { ok: false, reason: "invalid_response" });
  }
});

Deno.test("provider errors and network faults are reported without detail", async () => {
  eq(await createRazorpayOrder(CFG, INPUT, reply({ error: { description: "secret detail" } }, 400)), { ok: false, reason: "provider_error" });
  eq(await createRazorpayOrder(CFG, INPUT, () => Promise.reject(new Error("net"))), { ok: false, reason: "provider_error" });
  eq(await createRazorpayOrder(CFG, { ...INPUT, amountPaise: 0 }, reply({})), { ok: false, reason: "provider_error" });
});
