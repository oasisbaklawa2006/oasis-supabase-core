export type PaymentProviderRuntimeConfig = {
  adapterCode: "merchant_salt_hmac_json_v1";
  providerCode: "generic";
  webhookSignatureHeader: string;
};

export type PaymentProviderCreateInput = {
  merchantId: string;
  saltKey: string;
  transactionId: string;
  amountMinor: number;
  currency: string;
  webhookUrl: string;
  metadata: Record<string, string>;
};

export type PaymentProviderSession = {
  providerOrderId: string;
  providerSessionId: string;
  checkoutUrl: string;
  amountMinor: number;
  currency: string;
};

export type PaymentProviderEvent =
  | {
      kind: "payment_success";
      providerEventId: string;
      providerOrderId: string;
      providerPaymentId: string;
      amountMinor: number;
      currency: string;
    }
  | {
      kind: "payment_failed";
      providerEventId: string;
      providerOrderId: string;
      providerPaymentId: string;
      amountMinor: number | null;
      currency: string | null;
    };

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return bytesToHex(new Uint8Array(signature));
}

export function constantTimeEqualHex(left: string, right: string): boolean {
  const a = left.trim().toLowerCase();
  const b = right.trim().toLowerCase();
  if (!/^[0-9a-f]+$/.test(a) || !/^[0-9a-f]+$/.test(b) || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function httpsUrl(value: unknown): string | null {
  const candidate = text(value);
  if (!candidate) return null;
  try {
    const url = new URL(candidate);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

export function parsePaymentProviderCreateSessionUrl(value: unknown): string | null {
  const candidate = text(value);
  if (!candidate) return null;

  try {
    const url = new URL(candidate);
    const hostname = url.hostname.toLowerCase();

    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      (url.port && url.port !== "443") ||
      url.hash ||
      !hostname.includes(".") ||
      hostname === "localhost" ||
      hostname.endsWith(".localhost") ||
      hostname.endsWith(".local") ||
      hostname.endsWith(".internal") ||
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname) ||
      hostname.includes(":")
    ) {
      return null;
    }

    return url.toString();
  } catch {
    return null;
  }
}

function paymentProviderCreateSessionUrl(): string {
  const endpoint = parsePaymentProviderCreateSessionUrl(
    Deno.env.get("PAYMENT_GATEWAY_CREATE_SESSION_URL"),
  );
  if (!endpoint) {
    throw new Error("payment provider session endpoint is not configured");
  }
  return endpoint;
}

export function parsePaymentProviderRuntimeConfig(value: unknown): PaymentProviderRuntimeConfig | null {
  const row = record(value);
  if (!row || row.adapter_code !== "merchant_salt_hmac_json_v1" || row.provider_code !== "generic") return null;
  const webhookSignatureHeader = text(row.webhook_signature_header)?.toLowerCase() ?? null;
  if (!webhookSignatureHeader || !/^[a-z0-9-]+$/.test(webhookSignatureHeader)) return null;
  return {
    adapterCode: "merchant_salt_hmac_json_v1",
    providerCode: "generic",
    webhookSignatureHeader,
  };
}

export function toMinorUnits(amount: number): number {
  if (!Number.isFinite(amount) || amount <= 0) throw new Error("invalid canonical amount");
  const minor = Math.round(amount * 100);
  if (Math.abs(minor / 100 - amount) > 0.000001) throw new Error("canonical amount has unsupported precision");
  return minor;
}

export async function verifyPaymentProviderWebhook(
  saltKey: string,
  rawBody: string,
  suppliedSignature: string | null,
): Promise<boolean> {
  if (!saltKey || !suppliedSignature) return false;
  const expected = await hmacSha256Hex(saltKey, rawBody);
  return constantTimeEqualHex(expected, suppliedSignature);
}

export async function createMerchantSaltHmacJsonSession(
  input: PaymentProviderCreateInput,
): Promise<PaymentProviderSession> {
  const canonical = [
    input.merchantId,
    input.transactionId,
    String(input.amountMinor),
    input.currency.toUpperCase(),
  ].join("|");
  const signature = await hmacSha256Hex(input.saltKey, canonical);

  const response = await fetch(paymentProviderCreateSessionUrl(), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Merchant-Id": input.merchantId,
      "X-Payment-Signature": signature,
    },
    body: JSON.stringify({
      merchant_id: input.merchantId,
      transaction_id: input.transactionId,
      amount_minor: input.amountMinor,
      currency: input.currency.toUpperCase(),
      webhook_url: input.webhookUrl,
      metadata: input.metadata,
      signature,
    }),
    signal: AbortSignal.timeout(10_000),
  });

  const payload = await response.json().catch(() => null);
  if (!response.ok) throw new Error("provider session request failed");
  const row = record(payload);
  const providerOrderId = text(row?.provider_order_id);
  const providerSessionId = text(row?.session_id);
  const checkoutUrl = httpsUrl(row?.checkout_url);
  const amountMinor = finiteNumber(row?.amount_minor);
  const currency = text(row?.currency)?.toUpperCase() ?? null;
  if (
    !providerOrderId ||
    !providerSessionId ||
    !checkoutUrl ||
    amountMinor !== input.amountMinor ||
    currency !== input.currency.toUpperCase()
  ) {
    throw new Error("provider session binding mismatch");
  }

  return { providerOrderId, providerSessionId, checkoutUrl, amountMinor, currency };
}

export function parseMerchantSaltHmacJsonEvent(input: unknown): PaymentProviderEvent | null {
  const row = record(input);
  if (!row) return null;
  const eventType = text(row.event_type)?.toLowerCase();
  const providerEventId = text(row.event_id);
  const providerOrderId = text(row.provider_order_id);
  const providerPaymentId = text(row.provider_payment_id);
  if (!eventType || !providerEventId || !providerOrderId || !providerPaymentId) return null;

  const amountMinor = finiteNumber(row.amount_minor);
  const currency = text(row.currency)?.toUpperCase() ?? null;
  if (eventType === "payment_success") {
    if (amountMinor === null || amountMinor <= 0 || !currency) return null;
    return {
      kind: "payment_success",
      providerEventId,
      providerOrderId,
      providerPaymentId,
      amountMinor,
      currency,
    };
  }
  if (eventType === "payment_failed") {
    return {
      kind: "payment_failed",
      providerEventId,
      providerOrderId,
      providerPaymentId,
      amountMinor,
      currency,
    };
  }
  return null;
}
