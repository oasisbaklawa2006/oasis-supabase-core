import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  createMerchantSaltHmacJsonSession,
  parsePaymentProviderCreateSessionUrl,
  parsePaymentProviderRuntimeConfig,
  toMinorUnits,
} from "../_shared/paymentProviderAdapter.ts";

type Input = {
  order_id?: string;
  pi_id?: string | null;
  commercial_version_id?: string | null;
  payment_purpose?: string;
  correlation_id?: string;
  idempotency_key?: string;
};

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

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
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

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
  const publicKey = readNamedKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
  const secretKey = readNamedKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  const merchantId = Deno.env.get("PAYMENT_GATEWAY_MERCHANT_ID")?.trim();
  const saltKey = Deno.env.get("PAYMENT_GATEWAY_SALT_KEY")?.trim();
  const createSessionUrl = parsePaymentProviderCreateSessionUrl(
    Deno.env.get("PAYMENT_GATEWAY_CREATE_SESSION_URL"),
  );

  if (!supabaseUrl || !publicKey || !secretKey) {
    return json({ ok: false, error: "payment_service_unavailable" }, 503);
  }
  if (!merchantId || !saltKey) {
    return json({ ok: false, error: "payment_gateway_inactive" }, 503);
  }
  if (!createSessionUrl) {
    return json({ ok: false, error: "payment_gateway_endpoint_not_configured" }, 503);
  }

  let input: Input;
  try {
    input = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const orderId = text(input.order_id);
  const purpose = text(input.payment_purpose);
  const correlationId = text(input.correlation_id);
  const idempotencyKey = text(input.idempotency_key);
  if (!orderId || !purpose || !correlationId || !idempotencyKey) {
    return json({ ok: false, error: "payment_intent_fields_required" }, 400);
  }

  const userClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const token = authorization.slice(7);
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const userId = authData.user?.id ?? null;
  if (authError || !userId) return json({ ok: false, error: "unauthorized" }, 401);

  const admin = createClient(supabaseUrl, secretKey, { auth: { persistSession: false } });
  const { data: configData, error: configError } = await admin.rpc(
    "get_payment_gateway_provider_config_v1",
  );
  const config = parsePaymentProviderRuntimeConfig(configData);
  if (configError || !config) {
    return json({ ok: false, error: "payment_gateway_adapter_not_configured" }, 503);
  }

  const { data: intentData, error: intentError } = await userClient.rpc(
    "create_payment_gateway_payable_intent_v1",
    {
      p_order_id: orderId,
      p_pi_id: text(input.pi_id),
      p_commercial_version_id: text(input.commercial_version_id),
      p_payment_purpose: purpose,
      p_provider_code: "generic",
      p_correlation_id: correlationId,
      p_idempotency_key: idempotencyKey,
      p_actor_id: userId,
    },
  );
  if (intentError) {
    console.error("payment-provider-create-session canonical intent rejected", intentError.code);
    return json({ ok: false, error: "canonical_payment_intent_rejected" }, 409);
  }

  const intent = firstRow<{
    intent_id?: string;
    canonical_amount?: number | string;
    currency?: string;
    status?: string;
  }>(intentData);
  const intentId = text(intent?.intent_id);
  const canonicalAmount = Number(intent?.canonical_amount);
  const currency = text(intent?.currency)?.toUpperCase();
  if (!intentId || !Number.isFinite(canonicalAmount) || canonicalAmount <= 0 || currency !== "INR") {
    return json({ ok: false, error: "canonical_payment_intent_invalid" }, 502);
  }

  let amountMinor: number;
  try {
    amountMinor = toMinorUnits(canonicalAmount);
  } catch {
    return json({ ok: false, error: "canonical_amount_precision_invalid" }, 502);
  }

  const webhookUrl = `${supabaseUrl}/functions/v1/payment-provider-webhook`;
  let session;
  try {
    session = await createMerchantSaltHmacJsonSession({
      merchantId,
      saltKey,
      transactionId: intentId,
      amountMinor,
      currency,
      webhookUrl,
      metadata: {
        oasis_intent_id: intentId,
        oasis_order_id: orderId,
      },
    });
  } catch (error) {
    console.error(
      "payment-provider-create-session adapter failure",
      error instanceof Error ? error.message : "unknown",
    );
    return json({ ok: false, error: "provider_session_creation_failed" }, 502);
  }

  const { error: eventError } = await admin.rpc(
    "record_payment_gateway_verified_provider_event_v1",
    {
      p_intent_id: intentId,
      p_event_type: "order_created",
      p_provider_event_id: `session:${session.providerSessionId}`,
      p_provider_payment_id: null,
      p_provider_amount: canonicalAmount,
      p_provider_currency: currency,
      p_payload: {
        provider_order_id: session.providerOrderId,
        session_id: session.providerSessionId,
        amount_minor: session.amountMinor,
        currency: session.currency,
      },
      p_correlation_id: correlationId,
      p_idempotency_key: `provider-session:${intentId}:${session.providerSessionId}`,
      p_provider_order_id: session.providerOrderId,
    },
  );
  if (eventError) {
    console.error("payment-provider-create-session canonical provider record rejected", eventError.code);
    return json({ ok: false, error: "canonical_provider_session_record_failed" }, 502);
  }

  return json(
    {
      ok: true,
      intent_id: intentId,
      provider_order_id: session.providerOrderId,
      checkout_url: session.checkoutUrl,
      amount_minor: session.amountMinor,
      currency: session.currency,
      canonical_status: "pending",
      payment_success_requires_server_verification: true,
    },
    200,
  );
});
