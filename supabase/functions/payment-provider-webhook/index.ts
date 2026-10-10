import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  parseMerchantSaltHmacJsonEvent,
  parsePaymentProviderRuntimeConfig,
  verifyPaymentProviderWebhook,
} from "../_shared/paymentProviderAdapter.ts";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function firstRow<T>(value: unknown): T | null {
  if (Array.isArray(value)) return (value[0] as T | undefined) ?? null;
  return value && typeof value === "object" ? value as T : null;
}

function readNamedKey(jsonName: string, legacyName: string): string | null {
  const raw = Deno.env.get(jsonName);
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      const key = parsed?.default;
      if (typeof key === "string" && key.trim()) return key.trim();
    } catch {
      // Fall through to the legacy key for projects not yet migrated.
    }
  }
  return Deno.env.get(legacyName)?.trim() || null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
  const secretKey = readNamedKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  const merchantId = Deno.env.get("PAYMENT_GATEWAY_MERCHANT_ID")?.trim();
  const saltKey = Deno.env.get("PAYMENT_GATEWAY_SALT_KEY")?.trim();

  if (!supabaseUrl || !secretKey) {
    return json({ ok: false, error: "payment_service_unavailable" }, 503);
  }
  if (!merchantId || !saltKey) {
    return json({ ok: false, error: "payment_gateway_inactive" }, 503);
  }

  const admin = createClient(supabaseUrl, secretKey, { auth: { persistSession: false } });
  const { data: configData, error: configError } = await admin.rpc(
    "get_payment_gateway_provider_config_v1",
  );
  const config = parsePaymentProviderRuntimeConfig(configData);
  if (configError || !config) {
    return json({ ok: false, error: "payment_gateway_adapter_not_configured" }, 503);
  }

  const rawBody = await req.text();
  if (!rawBody || rawBody.length > 262_144) {
    return json({ ok: false, error: "invalid_webhook_body" }, 400);
  }

  const suppliedSignature = req.headers.get(config.webhookSignatureHeader);
  if (!(await verifyPaymentProviderWebhook(saltKey, rawBody, suppliedSignature))) {
    return json({ ok: false, error: "invalid_signature" }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const providerEvent = parseMerchantSaltHmacJsonEvent(payload);
  if (!providerEvent) {
    return json({ ok: true, ignored: true }, 202);
  }

  const { data: intentData, error: intentError } = await admin.rpc(
    "get_payment_gateway_intent_by_provider_order_v1",
    { p_provider_order_id: providerEvent.providerOrderId },
  );
  if (intentError) {
    console.error("payment-provider-webhook intent lookup failed", intentError.code);
    return json({ ok: false, error: "canonical_intent_lookup_failed" }, 409);
  }

  const intent = firstRow<Record<string, unknown>>(intentData) ??
    (intentData && typeof intentData === "object" ? intentData as Record<string, unknown> : null);
  const intentId = typeof intent?.intent_id === "string" ? intent.intent_id : null;
  const providerCode = typeof intent?.provider_code === "string" ? intent.provider_code : null;
  if (!intentId || providerCode !== "generic") {
    return json({ ok: false, error: "canonical_intent_provider_mismatch" }, 409);
  }

  const eventType = providerEvent.kind === "payment_success"
    ? "payment_success"
    : "payment_failed";
  const providerAmount = providerEvent.amountMinor === null
    ? null
    : providerEvent.amountMinor / 100;
  const correlationId = `payment-provider-webhook:${providerEvent.providerEventId}`;
  const idempotencyKey = `payment-provider-event:${providerEvent.providerEventId}`;

  const { data: eventData, error: eventError } = await admin.rpc(
    "record_payment_gateway_verified_provider_event_v1",
    {
      p_intent_id: intentId,
      p_event_type: eventType,
      p_provider_event_id: providerEvent.providerEventId,
      p_provider_payment_id: providerEvent.providerPaymentId,
      p_provider_amount: providerAmount,
      p_provider_currency: providerEvent.currency,
      p_payload: payload,
      p_correlation_id: correlationId,
      p_idempotency_key: idempotencyKey,
      p_provider_order_id: providerEvent.providerOrderId,
    },
  );
  if (eventError) {
    console.error("payment-provider-webhook canonical event rejected", eventError.code);
    return json({ ok: false, error: "canonical_provider_event_rejected" }, 409);
  }

  const eventRow = firstRow<{ provider_event_id?: string }>(eventData);
  const canonicalProviderEventId = eventRow?.provider_event_id ?? null;
  if (!canonicalProviderEventId) {
    return json({ ok: false, error: "canonical_provider_event_missing" }, 502);
  }

  if (providerEvent.kind !== "payment_success") {
    return json({ ok: true, settled: false, event: "payment_failed" }, 200);
  }

  const { data: settlementData, error: settlementError } = await admin.rpc(
    "settle_payment_gateway_intent_v1",
    {
      p_intent_id: intentId,
      p_provider_event_id: canonicalProviderEventId,
      p_correlation_id: `payment-provider-settle:${providerEvent.providerEventId}`,
      p_idempotency_key: `payment-provider-settle:${providerEvent.providerEventId}`,
    },
  );
  if (settlementError) {
    console.error("payment-provider-webhook canonical settlement rejected", settlementError.code);
    return json({ ok: false, error: "canonical_settlement_rejected" }, 409);
  }

  const settlement = firstRow<{
    status?: string;
    order_payment_id?: string;
    already_settled?: boolean;
  }>(settlementData);
  if (settlement?.status !== "success" || !settlement.order_payment_id) {
    return json({ ok: false, error: "canonical_settlement_incomplete" }, 502);
  }

  return json(
    {
      ok: true,
      settled: true,
      canonical_status: "success",
      already_settled: settlement.already_settled === true,
    },
    200,
  );
});
