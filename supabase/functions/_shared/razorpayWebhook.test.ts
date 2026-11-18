import { extractEvent, handleRazorpayWebhook, MAX_WEBHOOK_BYTES, razorpaySignature, sha256Hex, type RpcResult } from "./razorpayWebhook.ts";

function assert(c: unknown, m = "assertion failed"): asserts c {
  if (!c) throw new Error(m);
}
function eq(a: unknown, b: unknown, m = ""): void {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m || "values differ"}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const SECRET = "whsec_test_secret";
// Independent vectors computed with openssl, not with this code.
const BODY = '{"event":"payment.captured"}';
const BODY_HMAC = "e5fa4af2825f2f0153e20fe54892da0757c269be918d9ede705ccb272de19cae";
const BODY_SHA = "a24584972e33e732e2047555069c83f295efbb23cd920f6a8c097700616da954";

const captured = {
  event: "payment.captured",
  payload: { payment: { entity: { id: "pay_ABC123", order_id: "order_TESTAAAA0001", amount: 38700, currency: "INR", status: "captured" } } },
};

function setup(applyResult: RpcResult | Error = { data: { outcome: "applied", duplicate: false }, error: null }) {
  const applied: Array<Record<string, unknown>> = [];
  const rejected: Array<[string, string]> = [];
  return {
    applied,
    rejected,
    deps: {
      secret: SECRET,
      apply: (args: Record<string, unknown>) => {
        applied.push(args);
        return applyResult instanceof Error ? Promise.reject(applyResult) : Promise.resolve(applyResult);
      },
      reject: (hash: string, reason: string) => {
        rejected.push([hash, reason]);
        return Promise.resolve();
      },
    },
  };
}

async function signed(body: string, headers: Record<string, string> = {}, secret = SECRET): Promise<Request> {
  return new Request("https://core.example.test/functions/v1/razorpay-webhook", {
    method: "POST",
    headers: { "x-razorpay-signature": await razorpaySignature(body, secret), "x-razorpay-event-id": "evt_1", ...headers },
    body,
  });
}

Deno.test("signature and hash match independently computed vectors", async () => {
  eq(await razorpaySignature(BODY, SECRET), BODY_HMAC);
  eq(await sha256Hex(BODY), BODY_SHA);
});

Deno.test("a correctly signed event is applied once with the extracted money fields and the raw-body hash", async () => {
  const { deps, applied } = setup();
  const raw = JSON.stringify(captured);
  const res = await handleRazorpayWebhook(await signed(raw), deps);
  eq(res.status, 200);
  eq((await res.json()).outcome, "applied");
  eq(applied.length, 1);
  eq(applied[0]!.p_provider_event_id, "evt_1");
  eq(applied[0]!.p_provider_order_id, "order_TESTAAAA0001");
  eq(applied[0]!.p_amount_paise, 38700);
  eq(applied[0]!.p_currency, "INR");
  eq(applied[0]!.p_payload_hash, await sha256Hex(raw));
});

Deno.test("a wrong signature is rejected, logged, and never applied", async () => {
  const { deps, applied, rejected } = setup();
  const res = await handleRazorpayWebhook(await signed(JSON.stringify(captured), {}, "another-secret"), deps);
  eq(res.status, 401);
  eq(applied.length, 0);
  eq(rejected[0]![1], "signature_invalid");
});

Deno.test("a signature over a different body (tampering) is rejected", async () => {
  const { deps, applied } = setup();
  const original = JSON.stringify(captured);
  const req = new Request("https://core.example.test/x", {
    method: "POST",
    headers: { "x-razorpay-signature": await razorpaySignature(original, SECRET), "x-razorpay-event-id": "evt_1" },
    body: original.replace("38700", "100"),
  });
  eq((await handleRazorpayWebhook(req, deps)).status, 401);
  eq(applied.length, 0);
});

Deno.test("a missing signature is rejected before the body is interpreted", async () => {
  const { deps, applied, rejected } = setup();
  const req = new Request("https://core.example.test/x", { method: "POST", headers: { "x-razorpay-event-id": "evt_1" }, body: JSON.stringify(captured) });
  eq((await handleRazorpayWebhook(req, deps)).status, 401);
  eq(applied.length, 0);
  eq(rejected[0]![1], "signature_missing");
});

Deno.test("an unconfigured secret processes nothing", async () => {
  const { deps, applied } = setup();
  const res = await handleRazorpayWebhook(await signed(JSON.stringify(captured)), { ...deps, secret: "" });
  eq(res.status, 503);
  eq(applied.length, 0);
});

Deno.test("a signed event without an event id is refused (idempotency needs it)", async () => {
  const { deps, applied, rejected } = setup();
  const raw = JSON.stringify(captured);
  const req = new Request("https://core.example.test/x", { method: "POST", headers: { "x-razorpay-signature": await razorpaySignature(raw, SECRET) }, body: raw });
  eq((await handleRazorpayWebhook(req, deps)).status, 400);
  eq(applied.length, 0);
  eq(rejected[0]![1], "event_id_missing");
});

Deno.test("signed but malformed JSON is refused", async () => {
  const { deps, applied, rejected } = setup();
  for (const body of ["{nope", "[]", "null"]) {
    eq((await handleRazorpayWebhook(await signed(body), deps)).status, 400, body);
  }
  eq(applied.length, 0);
  assert(rejected.every((r) => r[1] === "payload_invalid"));
});

Deno.test("only POST is accepted and oversized bodies are refused", async () => {
  const { deps } = setup();
  eq((await handleRazorpayWebhook(new Request("https://core.example.test/x"), deps)).status, 405);
  const big = JSON.stringify({ ...captured, pad: "x".repeat(MAX_WEBHOOK_BYTES) });
  eq((await handleRazorpayWebhook(await signed(big), deps)).status, 413);
});

Deno.test("recorded outcomes (duplicate, unknown intent, mismatch) are acknowledged so the provider stops retrying", async () => {
  for (const outcome of ["applied", "unknown_intent", "amount_mismatch", "ignored_event_type"]) {
    const { deps } = setup({ data: { outcome, duplicate: outcome === "applied" }, error: null });
    const res = await handleRazorpayWebhook(await signed(JSON.stringify(captured)), deps);
    eq(res.status, 200, outcome);
    eq((await res.json()).outcome, outcome);
  }
});

Deno.test("database faults are retryable 503s; a conflicting redelivery is a 409", async () => {
  for (const result of [{ data: null, error: { message: "connection refused" } }, new Error("boom")] as Array<RpcResult | Error>) {
    const res = await handleRazorpayWebhook(await signed(JSON.stringify(captured)), setup(result).deps);
    eq(res.status, 503);
    assert(!(await res.text()).includes("connection refused"));
  }
  const conflict = await handleRazorpayWebhook(
    await signed(JSON.stringify(captured)),
    setup({ data: null, error: { message: "RETAIL_PAYMENT_EVENT_CONFLICT" } }).deps,
  );
  eq(conflict.status, 409);
  await conflict.body?.cancel();
});

Deno.test("order.paid events take the order and payment entities", () => {
  const e = extractEvent({
    event: "order.paid",
    payload: { payment: { entity: { id: "pay_X", amount: 500, currency: "INR" } }, order: { entity: { id: "order_TESTAAAA0001", amount: 500, currency: "INR" } } },
  });
  eq([e.eventType, e.providerOrderId, e.providerPaymentId, e.amountPaise, e.currency], ["order.paid", "order_TESTAAAA0001", "pay_X", 500, "INR"]);
  eq(extractEvent({ event: "x" }).providerOrderId, null);
  eq(extractEvent({ event: "payment.captured", payload: { payment: { entity: { order_id: "o", amount: 1.5 } } } }).amountPaise, null);
});
