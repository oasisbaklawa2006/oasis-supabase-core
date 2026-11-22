// Razorpay order creation for the retail checkout (SANDBOX ONLY in this version).
//
// Pure and injectable: the caller supplies fetch and the credentials. Live keys (`rzp_live_`) are refused so
// that this code path cannot activate live payments; enabling live mode is a separate, approved change.

export const RAZORPAY_ORDERS_URL = "https://api.razorpay.com/v1/orders";
export const RAZORPAY_TIMEOUT_MS = 10_000;

export type RazorpayConfig = { keyId: string; keySecret: string };
export type RazorpayOrderInput = { amountPaise: number; currency: "INR"; receipt: string; notes?: Record<string, string> };
export type RazorpayOrderResult = { ok: true; orderId: string } | { ok: false; reason: "not_configured" | "live_keys_refused" | "provider_error" | "invalid_response" };

const ORDER_ID_RE = /^order_[A-Za-z0-9]{6,40}$/;

export function sandboxConfig(
  keyId: string | undefined,
  keySecret: string | undefined,
): { ok: true; config: RazorpayConfig } | { ok: false; reason: "not_configured" | "live_keys_refused" } {
  const id = (keyId ?? "").trim();
  const secret = (keySecret ?? "").trim();
  if (!id || !secret) return { ok: false, reason: "not_configured" };
  if (!id.startsWith("rzp_test_")) return { ok: false, reason: "live_keys_refused" };
  return { ok: true, config: { keyId: id, keySecret: secret } };
}

export async function createRazorpayOrder(
  config: RazorpayConfig,
  input: RazorpayOrderInput,
  fetchImpl: typeof fetch = fetch,
): Promise<RazorpayOrderResult> {
  if (!config.keyId.startsWith("rzp_test_")) return { ok: false, reason: "live_keys_refused" };
  if (!Number.isInteger(input.amountPaise) || input.amountPaise <= 0) return { ok: false, reason: "provider_error" };
  try {
    const res = await fetchImpl(RAZORPAY_ORDERS_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Basic ${btoa(`${config.keyId}:${config.keySecret}`)}`,
      },
      body: JSON.stringify({
        amount: input.amountPaise,
        currency: input.currency,
        receipt: input.receipt,
        notes: input.notes ?? {},
      }),
      signal: AbortSignal.timeout(RAZORPAY_TIMEOUT_MS),
    });
    if (!res.ok) return { ok: false, reason: "provider_error" };
    const body = (await res.json().catch(() => null)) as Record<string, unknown> | null;
    // Never trust the provider echo blindly: the id must be well-formed and the amount must match what we asked for.
    if (
      !body || typeof body.id !== "string" || !ORDER_ID_RE.test(body.id) ||
      body.amount !== input.amountPaise || body.currency !== input.currency
    ) return { ok: false, reason: "invalid_response" };
    return { ok: true, orderId: body.id };
  } catch {
    return { ok: false, reason: "provider_error" };
  }
}
