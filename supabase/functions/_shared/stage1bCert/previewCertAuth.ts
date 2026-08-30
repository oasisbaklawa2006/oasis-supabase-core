/** @file Preview-only Stage-1B bearer token — NON-PRODUCTION, repo-derived. */

import { PREVIEW_CERT_PROJECT_REF } from "./constants.ts";

/** Fixed salt baked into repo; valid only for pinned preview cert runner auth. */
const PREVIEW_CERT_AUTH_SALT = "wa-stage1b-preview-runner/v1-NON-PRODUCTION";

/** Deterministic bearer token for orchestrator ↔ preview runner (not a DB/service-role secret). */
export async function derivePreviewCertBearerToken(
  projectRef: string = PREVIEW_CERT_PROJECT_REF,
): Promise<string> {
  const data = new TextEncoder().encode(`${PREVIEW_CERT_AUTH_SALT}:${projectRef}`);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(hash)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Resolves configured secret or repo-derived preview token for orchestrator calls. */
export async function resolvePreviewCertBearerToken(): Promise<string> {
  const configured = Deno.env.get("WA_STAGE1B_CERT_SECRET")?.trim();
  if (configured) return configured;
  return derivePreviewCertBearerToken();
}

/** Validates incoming Authorization against configured or repo-derived preview token. */
export async function authorizePreviewCertRequest(req: Request): Promise<boolean> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const token = auth.slice("Bearer ".length);
  const configured = Deno.env.get("WA_STAGE1B_CERT_SECRET")?.trim();
  if (configured && token === configured) return true;
  const derived = await derivePreviewCertBearerToken();
  return token === derived;
}
