import { extractVerifiedPhone, handleRetailCheckoutRequest, MAX_BODY_BYTES, type CheckoutDeps, type RpcResult } from "./retailCheckout.ts";

function assert(c: unknown, m = "assertion failed"): asserts c {
  if (!c) throw new Error(m);
}
function eq(a: unknown, b: unknown, m = ""): void {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m || "values differ"}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const TOKEN = "rsess_" + "a".repeat(64);
const UUID = "6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6e";

type Call = { name: string; args: Record<string, unknown> };
function harness(opts: {
  rpc?: (name: string, args: Record<string, unknown>) => RpcResult | Promise<RpcResult> | Error;
  verify?: Awaited<ReturnType<CheckoutDeps["verifyPhone"]>>;
  razorpay?: CheckoutDeps["razorpay"];
  origins?: string[];
} = {}) {
  const calls: Call[] = [];
  const razorpayCalls: unknown[] = [];
  const deps: CheckoutDeps = {
    rpc: (name, args) => {
      calls.push({ name, args });
      const r = (opts.rpc ?? (() => ({ data: {}, error: null })))(name, args);
      return r instanceof Error ? Promise.reject(r) : Promise.resolve(r);
    },
    verifyPhone: () => Promise.resolve(opts.verify ?? { ok: true, phone: "919876543210" }),
    razorpay: opts.razorpay === undefined
      ? { keyId: "rzp_test_abc", create: (i) => { razorpayCalls.push(i); return Promise.resolve({ ok: true, orderId: "order_TESTAAAA0001" }); } }
      : opts.razorpay,
    allowedOrigins: opts.origins ?? [],
  };
  return { deps, calls, razorpayCalls };
}

function post(route: string, body: unknown, headers: Record<string, string | undefined> = {}): Request {
  const h: Record<string, string> = { "content-type": "application/json" };
  for (const [k, v] of Object.entries(headers)) if (v !== undefined) h[k] = v;
  return new Request(`https://core.example.test/functions/v1/retail-checkout/${route}`, {
    method: "POST",
    headers: h,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
const authed = { authorization: `Bearer ${TOKEN}` };

Deno.test("a verified phone becomes a guest session and the phone is never echoed", async () => {
  const { deps, calls } = harness({ rpc: () => ({ data: { sessionToken: TOKEN, expiresAt: "2026-11-19T10:00:00Z" }, error: null }) });
  const res = await handleRetailCheckoutRequest(post("session", { accessToken: "widget-token" }), deps);
  eq(res.status, 201);
  const text = await res.text();
  assert(text.includes(TOKEN) && !text.includes("919876543210"));
  eq(calls[0], { name: "retail_session_issue_v1", args: { p_verified_phone: "919876543210" } });
});

Deno.test("an unverified widget token never reaches the database", async () => {
  const { deps, calls } = harness({ verify: { ok: false } });
  const res = await handleRetailCheckoutRequest(post("session", { accessToken: "bad" }), deps);
  eq(res.status, 401);
  eq(calls.length, 0);
  await res.body?.cancel();
  eq((await handleRetailCheckoutRequest(post("session", {}), deps)).status, 422);
});

Deno.test("price display validates ids and needs no session", async () => {
  const { deps, calls } = harness({ rpc: () => ({ data: { priceDisplayMode: "inclusive", items: [] }, error: null }) });
  eq((await handleRetailCheckoutRequest(post("price-display", { productIds: [UUID.toUpperCase()] }), deps)).status, 200);
  eq(calls[0]!.args, { p_product_ids: [UUID] });
  for (const productIds of [[], ["nope"], "x", Array(101).fill(UUID)]) {
    const res = await handleRetailCheckoutRequest(post("price-display", { productIds }), deps);
    eq(res.status, 422);
    await res.body?.cancel();
  }
});

Deno.test("session-scoped routes refuse a missing or malformed session before any database call", async () => {
  const { deps, calls } = harness();
  for (const route of ["quote", "order", "payment-intent", "session/revoke"]) {
    for (const authorization of [undefined, "Bearer nope", "Basic abc"]) {
      const res = await handleRetailCheckoutRequest(post(route, {}, { authorization }), deps);
      eq(res.status, 401, route);
      await res.body?.cancel();
    }
  }
  eq(calls.length, 0);
});

Deno.test("quote forwards the body untouched and distinguishes first delivery from replay", async () => {
  const body = { idempotencyKey: UUID, items: [{ productId: UUID, quantity: 1 }], shipTo: { pincode: "110015", stateCode: "07" } };
  const first = harness({ rpc: () => ({ data: { quoteId: UUID, replayed: false }, error: null }) });
  eq((await handleRetailCheckoutRequest(post("quote", body, authed), first.deps)).status, 201);
  eq(first.calls[0], { name: "retail_quote_create_v2", args: { p_session_token: TOKEN, p_request: body } });
  const replay = harness({ rpc: () => ({ data: { quoteId: UUID, replayed: true }, error: null }) });
  eq((await handleRetailCheckoutRequest(post("quote", body, authed), replay.deps)).status, 200);
});

Deno.test("database refusals map to stable statuses and leak no internals", async () => {
  const table: Array<[string, number, string]> = [
    ["RETAIL_COMMERCE_BLOCKED", 409, "commerce_blocked"],
    ["RETAIL_PRICE_MODE_UNSUPPORTED", 409, "commerce_blocked"],
    ["RETAIL_PAYMENT_PROVIDER_UNSUPPORTED", 409, "commerce_blocked"],
    ["RETAIL_SESSION_INVALID", 401, "session_invalid"],
    ["RETAIL_PIN_NOT_SERVICEABLE", 422, "pin_not_serviceable"],
    ["RETAIL_SHIPPING_UNPRICED", 409, "shipping_unpriced"],
    ["RETAIL_QUOTE_NOT_FOUND", 404, "not_found"],
    ["RETAIL_ORDER_NOT_FOUND", 404, "not_found"],
    ["RETAIL_QUOTE_EXPIRED", 410, "quote_expired"],
    ["RETAIL_ORDER_EXPIRED", 410, "order_expired"],
    ["RETAIL_QUOTE_REQUEST_INVALID", 422, "invalid_request"],
    ["RETAIL_QUOTE_IDEMPOTENCY_CONFLICT", 409, "conflict"],
    ["RETAIL_QUOTE_ALREADY_ORDERED", 409, "conflict"],
    ["RETAIL_ORDER_NOT_PAYABLE", 409, "conflict"],
    ["could not connect to server at 10.0.0.1", 503, "unavailable"],
  ];
  for (const [message, status, error] of table) {
    const { deps } = harness({ rpc: () => ({ data: null, error: { message, details: '{"missingOrUnapproved":["shipping.model"]}' } }) });
    const res = await handleRetailCheckoutRequest(post("quote", {}, authed), deps);
    eq(res.status, status, message);
    const text = await res.text();
    eq(JSON.parse(text).error, error, message);
    assert(!text.includes("shipping.model") && !text.includes("10.0.0.1"), `no internal detail for ${message}`);
  }
  const thrown = harness({ rpc: () => new Error("boom") });
  eq((await handleRetailCheckoutRequest(post("quote", {}, authed), thrown.deps)).status, 503);
});

Deno.test("unsellable products are reported by id only", async () => {
  const { deps } = harness({ rpc: () => ({ data: null, error: { message: "RETAIL_PRODUCT_NOT_SELLABLE", details: `{"products":["${UUID}:tax_rate_conflict"]}` } }) });
  const res = await handleRetailCheckoutRequest(post("quote", {}, authed), deps);
  eq(res.status, 422);
  const body = await res.json();
  eq(body, { error: "product_not_sellable", productIds: [UUID] });
});

Deno.test("order requires UUIDs and never forwards anything else", async () => {
  const { deps, calls } = harness({ rpc: () => ({ data: { orderId: UUID, replayed: false }, error: null }) });
  eq((await handleRetailCheckoutRequest(post("order", { quoteId: UUID, idempotencyKey: UUID, extra: "ignored" }, authed), deps)).status, 201);
  eq(calls[0]!.args, { p_session_token: TOKEN, p_quote_id: UUID, p_idempotency_key: UUID });
  const res = await handleRetailCheckoutRequest(post("order", { quoteId: "x", idempotencyKey: UUID }, authed), deps);
  eq(res.status, 422);
  await res.body?.cancel();
});

Deno.test("payment intent creates a Razorpay order and associates it with the intent", async () => {
  const intent = { intentId: UUID, amountPaise: 38700, currency: "INR", receipt: UUID, providerOrderId: null };
  const { deps, calls, razorpayCalls } = harness({
    rpc: (name) => (name === "retail_payment_intent_create_v1" ? { data: intent, error: null } : { data: { status: "associated" }, error: null }),
  });
  const res = await handleRetailCheckoutRequest(post("payment-intent", { orderId: UUID }, authed), deps);
  eq(res.status, 201);
  eq(await res.json(), { keyId: "rzp_test_abc", razorpayOrderId: "order_TESTAAAA0001", amountPaise: 38700, currency: "INR" });
  eq(razorpayCalls[0], { amountPaise: 38700, currency: "INR", receipt: UUID, notes: { intent: UUID } });
  eq(calls[1], { name: "retail_payment_intent_associate_v1", args: { p_intent_id: UUID, p_provider_order_id: "order_TESTAAAA0001", p_amount_paise: 38700, p_currency: "INR" } });
});

Deno.test("an intent that already has a provider order is returned without calling Razorpay again", async () => {
  const intent = { intentId: UUID, amountPaise: 38700, currency: "INR", receipt: UUID, providerOrderId: "order_TESTAAAA0001" };
  const { deps, razorpayCalls } = harness({ rpc: () => ({ data: intent, error: null }) });
  eq((await handleRetailCheckoutRequest(post("payment-intent", { orderId: UUID }, authed), deps)).status, 200);
  eq(razorpayCalls.length, 0);
});

Deno.test("payment is unavailable without sandbox credentials, and a provider failure associates nothing", async () => {
  const intent = { intentId: UUID, amountPaise: 38700, currency: "INR", receipt: UUID, providerOrderId: null };
  const none = harness({ rpc: () => ({ data: intent, error: null }), razorpay: null });
  const r1 = await handleRetailCheckoutRequest(post("payment-intent", { orderId: UUID }, authed), none.deps);
  eq(r1.status, 503);
  await r1.body?.cancel();
  const failing = harness({
    rpc: () => ({ data: intent, error: null }),
    razorpay: { keyId: "rzp_test_abc", create: () => Promise.resolve({ ok: false, reason: "provider_error" }) },
  });
  const r2 = await handleRetailCheckoutRequest(post("payment-intent", { orderId: UUID }, authed), failing.deps);
  eq(r2.status, 502);
  await r2.body?.cancel();
  eq(failing.calls.map((c) => c.name), ["retail_payment_intent_create_v1"]);
});

Deno.test("a blocked payment action stops before any provider call", async () => {
  const { deps, razorpayCalls } = harness({ rpc: () => ({ data: null, error: { message: "RETAIL_COMMERCE_BLOCKED" } }) });
  const res = await handleRetailCheckoutRequest(post("payment-intent", { orderId: UUID }, authed), deps);
  eq(res.status, 409);
  await res.body?.cancel();
  eq(razorpayCalls.length, 0);
});

Deno.test("transport rules: JSON only, size cap, POST only, unknown routes, CORS allow-list", async () => {
  const { deps } = harness();
  const wrongType = await handleRetailCheckoutRequest(post("quote", "{}", { ...authed, "content-type": "text/plain" }), deps);
  eq(wrongType.status, 415);
  await wrongType.body?.cancel();
  const big = await handleRetailCheckoutRequest(post("quote", { pad: "x".repeat(MAX_BODY_BYTES) }, authed), deps);
  eq(big.status, 413);
  await big.body?.cancel();
  const badJson = await handleRetailCheckoutRequest(post("quote", "{nope", authed), deps);
  eq(badJson.status, 400);
  await badJson.body?.cancel();
  const get = await handleRetailCheckoutRequest(new Request("https://core.example.test/functions/v1/retail-checkout/quote"), deps);
  eq(get.status, 405);
  await get.body?.cancel();
  const unknown = await handleRetailCheckoutRequest(post("teleport", {}, authed), deps);
  eq(unknown.status, 404);
  await unknown.body?.cancel();

  const cors = harness({ origins: ["https://shop.example.test"] }).deps;
  const allowed = await handleRetailCheckoutRequest(post("price-display", { productIds: [UUID] }, { origin: "https://shop.example.test" }), cors);
  eq(allowed.headers.get("access-control-allow-origin"), "https://shop.example.test");
  await allowed.body?.cancel();
  const denied = await handleRetailCheckoutRequest(post("price-display", { productIds: [UUID] }, { origin: "https://evil.example.test" }), cors);
  eq(denied.headers.get("access-control-allow-origin"), null);
  await denied.body?.cancel();
  const pre = await handleRetailCheckoutRequest(new Request("https://core.example.test/x", { method: "OPTIONS", headers: { origin: "https://evil.example.test" } }), cors);
  eq(pre.status, 403);
  const preOk = await handleRetailCheckoutRequest(new Request("https://core.example.test/x", { method: "OPTIONS", headers: { origin: "https://shop.example.test" } }), cors);
  eq(preOk.status, 204);
  const none = await handleRetailCheckoutRequest(post("price-display", { productIds: [UUID] }, { origin: "https://shop.example.test" }), harness().deps);
  eq(none.headers.get("access-control-allow-origin"), null, "server-to-server by default");
  await none.body?.cancel();
});

Deno.test("streaming body limit cancels at the first overflow chunk without an RPC", async () => {
  for (const declared of [undefined, "1"]) {
    let pulls = 0;
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls++;
        controller.enqueue(new Uint8Array(1024));
        if (pulls === 64) controller.close();
      },
      cancel() {
        cancelled = true;
      },
    }, { highWaterMark: 0 });
    const headers = new Headers({ "content-type": "application/json", ...authed });
    if (declared) headers.set("content-length", declared);
    const req = new Request("https://core.example.test/functions/v1/retail-checkout/quote", {
      method: "POST",
      headers,
      body: stream,
    });
    const { deps, calls } = harness();
    const res = await handleRetailCheckoutRequest(req, deps);
    eq(res.status, 413);
    assert(cancelled, "source must be cancelled immediately on streamed overflow");
    eq(pulls, MAX_BODY_BYTES / 1024 + 1, "must not read more chunks after overflow");
    eq(calls.length, 0, "no database or provider calls on oversized body");
    await res.body?.cancel();
  }
});

Deno.test("declared excessive retail body is refused before reading any stream", async () => {
  let pulls = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulls++;
      controller.close();
    },
  }, { highWaterMark: 0 });
  const req = new Request("https://core.example.test/functions/v1/retail-checkout/quote", {
    method: "POST",
    headers: { "content-type": "application/json", "content-length": String(MAX_BODY_BYTES + 1), ...authed },
    body: stream,
  });
  const { deps, calls } = harness();
  const res = await handleRetailCheckoutRequest(req, deps);
  eq(res.status, 413);
  eq(pulls, 0);
  eq(calls.length, 0);
  await res.body?.cancel();
  await req.body?.cancel();
});

Deno.test("bounded retail reader accepts UTF-8 split across chunks", async () => {
  const body = { idempotencyKey: UUID, items: [{ productId: UUID, quantity: 1 }], shipTo: { pincode: "110015", stateCode: "07" }, note: "é😀" };
  const bytes = new TextEncoder().encode(JSON.stringify(body));
  let offset = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset >= bytes.length) controller.close();
      else controller.enqueue(bytes.slice(offset, ++offset));
    },
  }, { highWaterMark: 0 });
  const req = new Request("https://core.example.test/functions/v1/retail-checkout/quote", {
    method: "POST",
    headers: { "content-type": "application/json", ...authed },
    body: stream,
  });
  const { deps, calls } = harness();
  const res = await handleRetailCheckoutRequest(req, deps);
  eq(res.status, 201);
  eq((calls[0]?.args.p_request as { note: string }).note, "é😀");
  await res.body?.cancel();
});

Deno.test("verified phone extraction reads the same shapes msg91-otp reads", () => {
  eq(extractVerifiedPhone({ message: "919876543210" }), "919876543210");
  eq(extractVerifiedPhone({ message: { mobile: "9876543210" } }), "9876543210");
  eq(extractVerifiedPhone({ data: { user: { phone: "9876543210" } } }), "9876543210");
  eq(extractVerifiedPhone({ type: "success" }), null);
});
