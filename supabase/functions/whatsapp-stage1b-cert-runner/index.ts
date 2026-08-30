/**
 * NON-PRODUCTION preview-only Stage-1B certification runner.
 * Deploy ONLY to PR preview branches — never production.
 *
 * Uses Supabase-injected runtime credentials (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY).
 * Hard-pins project ref to jyezfiehhfgnvhzzffxr; aborts before first write otherwise.
 */
import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";
import { runStage1bPreviewCert, type CertRunRequest } from "../_shared/stage1bCert/engine.ts";
import { assertOrchestratorPreviewUrl } from "../_shared/stage1bCert/previewPin.ts";
import { PREVIEW_CERT_PROJECT_REF } from "../_shared/stage1bCert/constants.ts";

const JSON_HEADERS = { ...corsHeaders, "Content-Type": "application/json" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function authorize(req: Request): boolean {
  const secret = Deno.env.get("WA_STAGE1B_CERT_SECRET") ?? "";
  if (!secret) return false;
  const auth = req.headers.get("Authorization") ?? "";
  return auth === `Bearer ${secret}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!authorize(req)) return json({ ok: false, error: "unauthorized" }, 401);

  const orchestratorUrl = req.headers.get("X-WA-Cert-Preview-Url") ?? "";
  if (orchestratorUrl) {
    try {
      assertOrchestratorPreviewUrl(orchestratorUrl);
    } catch (error) {
      return json({
        ok: false,
        error: error instanceof Error ? error.message : "preview_url_rejected",
      }, 403);
    }
  }

  let body: CertRunRequest;
  try {
    body = await req.json() as CertRunRequest;
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  if (!Array.isArray(body.fixtures) || !body.fixtures.length) {
    return json({ ok: false, error: "fixtures_required" }, 400);
  }

  try {
    const report = await runStage1bPreviewCert(body);
    const status = report.status === "COMPLETE" ? 200 : report.status === "FAILED" ? 422 : 503;
    return json({
      ok: report.status === "COMPLETE",
      preview_project_ref: PREVIEW_CERT_PROJECT_REF,
      non_production: true,
      report,
    }, status);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const blocked = message.includes("PREVIEW_PIN_FAILED") ||
      message.includes("PRODUCTION");
    return json({
      ok: false,
      error: message.slice(0, 500),
      preview_project_ref: PREVIEW_CERT_PROJECT_REF,
      non_production: true,
    }, blocked ? 403 : 500);
  }
});
