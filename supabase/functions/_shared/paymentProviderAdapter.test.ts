import {
  constantTimeEqualHex,
  hmacSha256Hex,
  parseMerchantSaltHmacJsonEvent,
  parsePaymentProviderCreateSessionUrl,
  parsePaymentProviderRuntimeConfig,
  toMinorUnits,
  verifyPaymentProviderWebhook,
} from "./paymentProviderAdapter.ts";

Deno.test("provider config is explicit, neutral and HTTPS-only", () => {
  const cfg = parsePaymentProviderRuntimeConfig({
    adapter_code: "merchant_salt_hmac_json_v1",
    provider_code: "generic",
    webhook_signature_header: "x-payment-signature",
  });
  if (!cfg || cfg.providerCode !== "generic") throw new Error("valid generic config rejected");
  if (parsePaymentProviderRuntimeConfig({
    adapter_code: "merchant_salt_hmac_json_v1",
    provider_code: "generic",
    webhook_signature_header: "bad header",
  }) !== null) throw new Error("invalid signature header must fail closed");
});

Deno.test("provider session endpoint is server-controlled public HTTPS only", () => {
  if (
    parsePaymentProviderCreateSessionUrl("https://gateway.example/session") !==
      "https://gateway.example/session"
  ) {
    throw new Error("valid public HTTPS endpoint rejected");
  }
  for (
    const rejected of [
      "http://gateway.example/session",
      "https://127.0.0.1/session",
      "https://10.0.0.1/session",
      "https://[::1]/session",
      "https://gateway.internal/session",
      "https://user:pass@gateway.example/session",
      "https://gateway.example:8443/session",
    ]
  ) {
    if (parsePaymentProviderCreateSessionUrl(rejected) !== null) {
      throw new Error(`unsafe provider endpoint accepted: ${rejected}`);
    }
  }
});

Deno.test("generic webhook HMAC is exact and mismatch fails", async () => {
  const body = '{"event_type":"payment_success"}';
  const testSigningKey = crypto.randomUUID();
  const signature = await hmacSha256Hex(testSigningKey, body);
  if (!(await verifyPaymentProviderWebhook(testSigningKey, body, signature))) {
    throw new Error("signature rejected");
  }
  if (await verifyPaymentProviderWebhook(testSigningKey, body, "00".repeat(32))) {
    throw new Error("bad signature accepted");
  }
  if (constantTimeEqualHex("abcd", "abce")) throw new Error("comparison accepted mismatch");
});

Deno.test("generic success event contains only bounded payment facts", () => {
  const event = parseMerchantSaltHmacJsonEvent({
    event_id: "evt_1",
    event_type: "payment_success",
    provider_order_id: "ord_1",
    provider_payment_id: "pay_1",
    amount_minor: 12345,
    currency: "inr",
  });
  if (!event || event.kind !== "payment_success") throw new Error("success event not parsed");
  if (event.amountMinor !== 12345 || event.currency !== "INR") throw new Error("event normalization mismatch");
});

Deno.test("unsupported or incomplete events fail closed", () => {
  if (parseMerchantSaltHmacJsonEvent({ event_type: "refund" }) !== null) {
    throw new Error("unsupported event accepted");
  }
  if (parseMerchantSaltHmacJsonEvent({
    event_id: "evt_2",
    event_type: "payment_success",
    provider_payment_id: "pay_2",
    amount_minor: 100,
    currency: "INR",
  }) !== null) throw new Error("missing provider order accepted");
});

Deno.test("canonical rupee amount converts exactly to minor units", () => {
  if (toMinorUnits(123.45) !== 12345) throw new Error("minor conversion mismatch");
  let rejected = false;
  try { toMinorUnits(1.001); } catch { rejected = true; }
  if (!rejected) throw new Error("unsupported precision accepted");
});
