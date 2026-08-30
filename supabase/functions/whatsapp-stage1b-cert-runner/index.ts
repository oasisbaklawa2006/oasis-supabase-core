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
import { authorizePreviewCertRequest } from "../_shared/stage1bCert/previewCertAuth.ts";
import { PREVIEW_CERT_PROJECT_REF } from "../_shared/stage1bCert/constants.ts";

const JSON_HEADERS = { ...corsHeaders, "Content-Type": "application/json" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!(await authorizePreviewCertRequest(req))) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

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
    if ((body as { probe_runtime_secrets?: boolean }).probe_runtime_secrets === true) {
      const { runtimeSecretReadiness, probeWorkerRuntime } = await import("../_shared/stage1bCert/worker.ts");
      const { assertPreviewCertRuntime } = await import("../_shared/stage1bCert/previewPin.ts");
      const { createClient } = await import("npm:@supabase/supabase-js@2.95.0");
      assertPreviewCertRuntime();
      const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
      const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const readiness = runtimeSecretReadiness();
      const runtime = await probeWorkerRuntime(admin);
      readiness.GEMINI_API_KEY_EDGE_RUNTIME = runtime.configured;
      return json({
        ok: runtime.configured,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        runtime_secret_readiness: readiness,
      }, runtime.configured ? 200 : 503);
    }
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
