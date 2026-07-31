const encoder = new TextEncoder();

export type VerificationResult =
  | { ok: true }
  | { ok: false; status: 401 | 403 | 500; code: string };

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) out[i / 2] = Number.parseInt(hex.slice(i, i + 2), 16);
  return out;
}

export function verifyChallengeToken(candidate: string | null, expected: string | undefined): VerificationResult {
  if (!expected) return { ok: false, status: 500, code: "verify_token_not_configured" };
  if (!candidate) return { ok: false, status: 403, code: "verify_token_missing" };
  const left = encoder.encode(candidate);
  const right = encoder.encode(expected);
  return timingSafeEqual(left, right)
    ? { ok: true }
    : { ok: false, status: 403, code: "verify_token_invalid" };
}

export async function verifyMetaSignature(
  rawBody: Uint8Array,
  signatureHeader: string | null,
  appSecret: string | undefined,
): Promise<VerificationResult> {
  if (!appSecret) return { ok: false, status: 500, code: "app_secret_not_configured" };
  if (!signatureHeader?.startsWith("sha256=")) {
    return { ok: false, status: 401, code: "signature_missing" };
  }
  const supplied = hexToBytes(signatureHeader.slice("sha256=".length));
  if (!supplied) return { ok: false, status: 401, code: "signature_malformed" };

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, rawBody));
  return timingSafeEqual(supplied, expected)
    ? { ok: true }
    : { ok: false, status: 401, code: "signature_invalid" };
}

export function safeWebhookHeaders(contentType = "application/json") {
  return {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
}
