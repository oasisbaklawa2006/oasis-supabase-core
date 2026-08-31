/** @file Preview-only Stage-1B bearer token — NON-PRODUCTION, secret-gated. */

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
  return token === configured;
}
