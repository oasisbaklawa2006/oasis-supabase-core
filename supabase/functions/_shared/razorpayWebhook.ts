// Razorpay webhook boundary for the retail checkout: verify the signature over the RAW body, then hand the event
// to the database, which stores it durably and applies it idempotently. Nothing unsigned is ever applied.

import { timingSafeEqualHex } from "./metaSignature.ts";

export const MAX_WEBHOOK_BYTES = 256 * 1024;

export type RpcResult = { data: unknown; error: { message?: string; code?: string } | null };
export type WebhookDeps = {
  secret: string;
  apply: (args: Record<string, unknown>) => Promise<RpcResult>;
  reject: (payloadHash: string, reason: string) => Promise<unknown>;
};

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

const toHex = (buf: ArrayBuffer): string => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function sha256Hex(text: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

export async function razorpaySignature(rawBody: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody)));
}

type Entity = Record<string, unknown>;
const asObj = (v: unknown): Entity | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Entity) : null);

/** Pull the provider order, payment, amount (paise) and currency out of a Razorpay event payload. */
export function extractEvent(payload: Entity): {
  eventType: string;
  providerOrderId: string | null;
  providerPaymentId: string | null;
  amountPaise: number | null;
  currency: string | null;
} {
  const eventType = typeof payload.event === "string" ? payload.event : "";
  const inner = asObj(payload.payload);
  const payment = asObj(asObj(inner?.payment)?.entity);
  const order = asObj(asObj(inner?.order)?.entity);
  const str = (v: unknown) => (typeof v === "string" && v ? v : null);
  const providerOrderId = str(payment?.order_id) ?? str(order?.id);
  const amount = typeof payment?.amount === "number" ? payment.amount : typeof order?.amount === "number" ? order.amount : null;
  return {
    eventType,
    providerOrderId,
    providerPaymentId: str(payment?.id),
    amountPaise: amount !== null && Number.isInteger(amount) ? amount : null,
    currency: str(payment?.currency) ?? str(order?.currency),
  };
}

export async function handleRazorpayWebhook(req: Request, deps: WebhookDeps): Promise<Response> {
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: { allow: "POST", "content-type": "application/json" } });
  // Without a configured secret nothing can be verified, so nothing may be applied.
  if (!deps.secret) return json(503, { error: "unavailable" });

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_WEBHOOK_BYTES) return json(413, { error: "payload_too_large" });
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_WEBHOOK_BYTES) return json(413, { error: "payload_too_large" });
  const payloadHash = await sha256Hex(raw);

  const provided = (req.headers.get("x-razorpay-signature") ?? "").trim().toLowerCase();
  if (!provided) {
    await deps.reject(payloadHash, "signature_missing").catch(() => undefined);
    return json(401, { error: "unauthorized" });
  }
  const expected = await razorpaySignature(raw, deps.secret);
  if (!timingSafeEqualHex(expected, provided)) {
    await deps.reject(payloadHash, "signature_invalid").catch(() => undefined);
    return json(401, { error: "unauthorized" });
  }

  const eventId = (req.headers.get("x-razorpay-event-id") ?? "").trim();
  if (!eventId || eventId.length > 200) {
    await deps.reject(payloadHash, "event_id_missing").catch(() => undefined);
    return json(400, { error: "event_id_required" });
  }
  let payload: Entity;
  try {
    const parsed = JSON.parse(raw);
    const obj = asObj(parsed);
    if (!obj) throw new Error("not an object");
    payload = obj;
  } catch {
    await deps.reject(payloadHash, "payload_invalid").catch(() => undefined);
    return json(400, { error: "invalid_payload" });
  }

  const e = extractEvent(payload);
  let result: RpcResult;
  try {
    result = await deps.apply({
      p_provider_event_id: eventId,
      p_event_type: e.eventType,
      p_provider_order_id: e.providerOrderId,
      p_provider_payment_id: e.providerPaymentId,
      p_amount_paise: e.amountPaise,
      p_currency: e.currency,
      p_payload: payload,
      p_payload_hash: payloadHash,
    });
  } catch {
    return json(503, { error: "unavailable" });
  }
  if (result.error) {
    // A conflicting redelivery will never succeed on retry; everything else is retryable infrastructure.
    if ((result.error.message ?? "").startsWith("RETAIL_PAYMENT_EVENT_CONFLICT")) return json(409, { error: "event_conflict" });
    return json(503, { error: "unavailable" });
  }
  const outcome = asObj(result.data);
  // Anything durably recorded (including unknown intent / amount mismatch) is acknowledged so the provider stops
  // retrying; the outcome is visible in the stored event for operations.
  return json(200, { received: true, outcome: typeof outcome?.outcome === "string" ? outcome.outcome : "unknown" });
}
