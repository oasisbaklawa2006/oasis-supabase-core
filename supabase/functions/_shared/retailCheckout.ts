// HTTP boundary for the retail (B2C) checkout: guest session, GST-inclusive price display, quote, order and
// Razorpay payment association. SANDBOX / CANDIDATE: every commercial action is gated inside the database by
// the approved retail_commerce_settings; this layer holds no business value and activates nothing.
//
// Pure request handling with injected dependencies so it is testable without Supabase, MSG91 or Razorpay.

import type { RazorpayOrderInput, RazorpayOrderResult } from "./razorpayOrders.ts";

export const MAX_BODY_BYTES = 32 * 1024;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type RpcResult = { data: unknown; error: { message?: string; code?: string; details?: string } | null };

export type CheckoutDeps = {
  rpc: (name: string, args: Record<string, unknown>) => Promise<RpcResult>;
  /** Verifies a MSG91 widget access token and returns the provider-verified phone in 91XXXXXXXXXX form. */
  verifyPhone: (accessToken: string) => Promise<{ ok: true; phone: string } | { ok: false }>;
  razorpay: null | { keyId: string; create: (input: RazorpayOrderInput) => Promise<RazorpayOrderResult> };
  /** Browser origins allowed to call this function. Empty means server-to-server only (no CORS headers). */
  allowedOrigins: string[];
};

type Headers = Record<string, string>;

function respond(status: number, body: unknown, cors: Headers, extra: Headers = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...cors, ...extra },
  });
}

/** Map a database exception to a stable HTTP result without echoing internal detail. */
export function mapRetailError(error: { message?: string; code?: string; details?: string }, cors: Headers): Response {
  const m = error.message ?? "";
  const starts = (...p: string[]) => p.some((x) => m.startsWith(x));
  if (starts("RETAIL_SESSION_INVALID")) {
    return respond(401, { error: "session_invalid" }, cors, { "www-authenticate": 'Bearer realm="retail-checkout"' });
  }
  if (starts("RETAIL_COMMERCE_BLOCKED", "RETAIL_PRICE_MODE_UNSUPPORTED", "RETAIL_PAYMENT_PROVIDER_UNSUPPORTED")) {
    return respond(409, { error: "commerce_blocked" }, cors);
  }
  if (starts("RETAIL_PIN_NOT_SERVICEABLE")) return respond(422, { error: "pin_not_serviceable" }, cors);
  if (starts("RETAIL_PRODUCT_NOT_SELLABLE")) {
    const ids = [...(error.details ?? "").matchAll(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi)].map((x) => x[0]);
    return respond(422, { error: "product_not_sellable", productIds: ids }, cors);
  }
  if (starts("RETAIL_SHIPPING_UNPRICED")) return respond(409, { error: "shipping_unpriced" }, cors);
  if (starts("RETAIL_QUOTE_NOT_FOUND", "RETAIL_ORDER_NOT_FOUND")) return respond(404, { error: "not_found" }, cors);
  if (starts("RETAIL_QUOTE_EXPIRED")) return respond(410, { error: "quote_expired" }, cors);
  if (starts("RETAIL_ORDER_EXPIRED")) return respond(410, { error: "order_expired" }, cors);
  if (starts("RETAIL_QUOTE_REQUEST_INVALID", "RETAIL_PHONE_INVALID", "RETAIL_ORDER_REQUEST_INVALID")) {
    return respond(422, { error: "invalid_request" }, cors);
  }
  if (starts("RETAIL_QUOTE_IDEMPOTENCY_CONFLICT", "RETAIL_ORDER_IDEMPOTENCY_CONFLICT", "RETAIL_QUOTE_ALREADY_ORDERED",
    "RETAIL_ORDER_NOT_PAYABLE", "RETAIL_PAYMENT_ASSOCIATION")) {
    return respond(409, { error: "conflict" }, cors);
  }
  return respond(503, { error: "unavailable" }, cors, { "retry-after": "30" });
}

/** Provider-verified phone out of a MSG91 widget verification response (same keys msg91-otp reads). */
export function extractVerifiedPhone(raw: Record<string, unknown>): string | null {
  const obj = (v: unknown): Record<string, unknown> | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
  const first = (...vs: unknown[]) => {
    for (const v of vs) if (typeof v === "string" && v.trim()) return v.trim();
    return null;
  };
  const message = obj(raw.message);
  const data = obj(raw.data);
  const user = obj(data?.user);
  return first(
    typeof raw.message === "string" ? raw.message : null, typeof raw.data === "string" ? raw.data : null,
    message?.mobile, message?.phone, message?.identifier, message?.number,
    data?.mobile, data?.phone, data?.identifier, data?.number,
    raw.mobile, raw.phone, raw.identifier, raw.number, user?.mobile, user?.phone,
  );
}

async function readJson(req: Request, cors: Headers): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; res: Response }> {
  if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
    return { ok: false, res: respond(415, { error: "unsupported_media_type" }, cors) };
  }
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return { ok: false, res: respond(413, { error: "payload_too_large" }, cors) };
  }
  // Never buffer an unbounded request before enforcing the byte limit.
  // Cancel at the first overflowing chunk, even if Content-Length is absent or forged.
  let text: string;
  try {
    const reader = req.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (reader) {
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_BODY_BYTES) {
            void reader.cancel().catch(() => {});
            return { ok: false, res: respond(413, { error: "payload_too_large" }, cors) };
          }
          chunks.push(value);
        }
      } finally {
        reader.releaseLock();
      }
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return { ok: false, res: respond(400, { error: "invalid_json" }, cors) };
  }
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("shape");
    return { ok: true, body: parsed as Record<string, unknown> };
  } catch {
    return { ok: false, res: respond(400, { error: "invalid_json" }, cors) };
  }
}

function bearer(req: Request): string | null {
  const m = /^Bearer\s+(rsess_[0-9a-f]{64})$/.exec(req.headers.get("authorization") ?? "");
  return m ? m[1]! : null;
}

export async function handleRetailCheckoutRequest(req: Request, deps: CheckoutDeps): Promise<Response> {
  const origin = req.headers.get("origin");
  const cors: Headers = origin && deps.allowedOrigins.includes(origin)
    ? { "access-control-allow-origin": origin, vary: "origin" }
    : {};
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: cors["access-control-allow-origin"] ? 204 : 403,
      headers: {
        ...cors,
        "access-control-allow-methods": "POST",
        "access-control-allow-headers": "authorization, content-type",
        "access-control-max-age": "600",
      },
    });
  }
  if (req.method !== "POST") return respond(405, { error: "method_not_allowed" }, cors, { allow: "POST" });

  const segments = new URL(req.url).pathname.split("/").filter(Boolean);
  const at = segments.indexOf("retail-checkout");
  const route = (at >= 0 ? segments.slice(at + 1) : segments.slice(-1)).join("/");

  const parsed = await readJson(req, cors);
  if (!parsed.ok) return parsed.res;
  const body = parsed.body;

  const call = async (name: string, args: Record<string, unknown>) => {
    try {
      return await deps.rpc(name, args);
    } catch {
      return { data: null, error: { message: "unavailable" } } as RpcResult;
    }
  };

  if (route === "session") {
    const accessToken = typeof body.accessToken === "string" ? body.accessToken : "";
    if (!accessToken || accessToken.length > 4096) return respond(422, { error: "invalid_request" }, cors);
    const verified = await deps.verifyPhone(accessToken);
    if (!verified.ok) return respond(401, { error: "verification_failed" }, cors);
    const issued = await call("retail_session_issue_v1", { p_verified_phone: verified.phone });
    if (issued.error) return mapRetailError(issued.error, cors);
    return respond(201, issued.data, cors);
  }

  if (route === "price-display") {
    const ids = body.productIds;
    if (!Array.isArray(ids) || ids.length < 1 || ids.length > 100 || !ids.every((x) => typeof x === "string" && UUID_RE.test(x))) {
      return respond(422, { error: "invalid_request" }, cors);
    }
    const r = await call("retail_price_display_v1", { p_product_ids: ids.map((x) => (x as string).toLowerCase()) });
    return r.error ? mapRetailError(r.error, cors) : respond(200, r.data, cors);
  }

  // Everything below needs a retail guest session.
  const token = bearer(req);
  if (!token) return respond(401, { error: "session_invalid" }, cors, { "www-authenticate": 'Bearer realm="retail-checkout"' });

  if (route === "session/revoke") {
    const r = await call("retail_session_revoke_v1", { p_session_token: token });
    return r.error ? mapRetailError(r.error, cors) : respond(200, { revoked: true }, cors);
  }

  if (route === "quote") {
    const r = await call("retail_quote_create_v2", { p_session_token: token, p_request: body });
    if (r.error) return mapRetailError(r.error, cors);
    return respond((r.data as { replayed?: boolean } | null)?.replayed ? 200 : 201, r.data, cors);
  }

  if (route === "order") {
    const quoteId = typeof body.quoteId === "string" ? body.quoteId : "";
    const key = typeof body.idempotencyKey === "string" ? body.idempotencyKey : "";
    if (!UUID_RE.test(quoteId) || !UUID_RE.test(key)) return respond(422, { error: "invalid_request" }, cors);
    const r = await call("retail_order_create_v1", { p_session_token: token, p_quote_id: quoteId.toLowerCase(), p_idempotency_key: key });
    if (r.error) return mapRetailError(r.error, cors);
    return respond((r.data as { replayed?: boolean } | null)?.replayed ? 200 : 201, r.data, cors);
  }

  if (route === "payment-intent") {
    const orderId = typeof body.orderId === "string" ? body.orderId : "";
    if (!UUID_RE.test(orderId)) return respond(422, { error: "invalid_request" }, cors);
    const intent = await call("retail_payment_intent_create_v1", { p_session_token: token, p_order_id: orderId.toLowerCase() });
    if (intent.error) return mapRetailError(intent.error, cors);
    const i = intent.data as { intentId: string; amountPaise: number; currency: "INR"; receipt: string; providerOrderId: string | null };
    if (!deps.razorpay) return respond(503, { error: "payment_provider_unavailable" }, cors, { "retry-after": "30" });
    if (i.providerOrderId) {
      return respond(200, { keyId: deps.razorpay.keyId, razorpayOrderId: i.providerOrderId, amountPaise: i.amountPaise, currency: i.currency }, cors);
    }
    const created = await deps.razorpay.create({ amountPaise: i.amountPaise, currency: i.currency, receipt: i.receipt, notes: { intent: i.intentId } });
    if (!created.ok) return respond(502, { error: "payment_provider_error" }, cors, { "retry-after": "30" });
    const assoc = await call("retail_payment_intent_associate_v1", {
      p_intent_id: i.intentId, p_provider_order_id: created.orderId, p_amount_paise: i.amountPaise, p_currency: i.currency,
    });
    if (assoc.error) return mapRetailError(assoc.error, cors);
    return respond(201, { keyId: deps.razorpay.keyId, razorpayOrderId: created.orderId, amountPaise: i.amountPaise, currency: i.currency }, cors);
  }

  return respond(404, { error: "not_found" }, cors);
}
