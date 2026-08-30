/** @file Fail-closed preview project identity guard — no override permitted. */

import {
  FORBIDDEN_PRODUCTION_REF,
  PREVIEW_CERT_PROJECT_REF,
} from "./constants.ts";

/** Extracts the Supabase project ref from a URL without logging secrets. */
export function projectRefFromSupabaseUrl(url: string): string | null {
  const match = url.replace(/\/$/, "").match(/https?:\/\/([^.]+)\.supabase\.co/i);
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
  if (projectRef !== PREVIEW_CERT_PROJECT_REF) {
    throw new Error(
      `PREVIEW_PIN_FAILED:UNEXPECTED_PROJECT_REF:${projectRef}`,
    );
  }
  if (supabaseUrl.includes(FORBIDDEN_PRODUCTION_REF)) {
    throw new Error("PREVIEW_PIN_FAILED:PRODUCTION_URL_FORBIDDEN");
  }

  return { supabaseUrl, projectRef };
}

/** Validates orchestrator-supplied preview URL matches the pinned cert target. */
export function assertOrchestratorPreviewUrl(url: string): void {
  const ref = projectRefFromSupabaseUrl(url);
  if (ref !== PREVIEW_CERT_PROJECT_REF) {
    throw new Error(`ORCHESTRATOR_PREVIEW_REJECTED:${ref ?? "unknown"}`);
  }
  if (url.includes(FORBIDDEN_PRODUCTION_REF)) {
    throw new Error("ORCHESTRATOR_PREVIEW_REJECTED:production_forbidden");
  }
}
