/** @file Preview-only Stage-1B bearer token — NON-PRODUCTION, secret-gated. */

const encoder = new TextEncoder();

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Resolves configured preview cert secret; fails closed when absent. */
export function resolvePreviewCertBearerToken(): string {
  const configured = Deno.env.get("WA_STAGE1B_CERT_SECRET")?.trim();
  if (!configured) {
    throw new Error("WA_STAGE1B_CERT_SECRET_REQUIRED");
  }
  return configured;
}

/** Validates incoming Authorization against configured preview cert secret only. */
export function authorizePreviewCertRequest(req: Request): boolean {
  const configured = Deno.env.get("WA_STAGE1B_CERT_SECRET")?.trim();
  if (!configured) return false;
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const token = auth.slice("Bearer ".length);
  return timingSafeEqual(encoder.encode(token), encoder.encode(configured));
}
