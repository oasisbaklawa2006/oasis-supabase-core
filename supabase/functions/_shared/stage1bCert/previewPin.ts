/** @file Fail-closed preview project identity guard — no override permitted. */

import { FORBIDDEN_PRODUCTION_REF } from "./constants.ts";

/** Extracts the Supabase project ref from a URL without logging secrets. */
export function projectRefFromSupabaseUrl(url: string): string | null {
  const match = url.replace(/\/$/, "").match(
    /^https:\/\/([a-z0-9]{20})\.supabase\.co$/,
  );
  return match?.[1] ?? null;
}

/** Aborts certification before first write if preview identity cannot be proven. */
export function assertPreviewCertRuntime(): {
  supabaseUrl: string;
  projectRef: string;
} {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "") ?? "";
  if (!supabaseUrl) {
    throw new Error("PREVIEW_PIN_FAILED:SUPABASE_URL_MISSING");
  }

  const projectRef = projectRefFromSupabaseUrl(supabaseUrl);
  if (!projectRef) {
    throw new Error("PREVIEW_PIN_FAILED:SUPABASE_URL_UNPARSEABLE");
  }
  if (projectRef === FORBIDDEN_PRODUCTION_REF) {
    throw new Error("PREVIEW_PIN_FAILED:PRODUCTION_REF_FORBIDDEN");
  }
  if (supabaseUrl.includes(FORBIDDEN_PRODUCTION_REF)) {
    throw new Error("PREVIEW_PIN_FAILED:PRODUCTION_URL_FORBIDDEN");
  }

  return { supabaseUrl, projectRef };
}

/** Validates the orchestrator URL matches the current runtime preview authority. */
export function assertOrchestratorPreviewUrl(
  url: string,
  expectedProjectRef?: string,
): void {
  const ref = projectRefFromSupabaseUrl(url);
  if (!ref) {
    throw new Error(`ORCHESTRATOR_PREVIEW_REJECTED:${ref ?? "unknown"}`);
  }
  if (
    ref === FORBIDDEN_PRODUCTION_REF || url.includes(FORBIDDEN_PRODUCTION_REF)
  ) {
    throw new Error("ORCHESTRATOR_PREVIEW_REJECTED:production_forbidden");
  }
  if (expectedProjectRef && ref !== expectedProjectRef) {
    throw new Error(`ORCHESTRATOR_PREVIEW_REJECTED:${ref}`);
  }
}
