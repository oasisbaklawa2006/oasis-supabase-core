/**
 * NON-PRODUCTION preview-only Stage-1B certification runner.
 * Deploy ONLY to PR preview branches — never production.
 *
 * Uses Supabase-injected runtime credentials (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY).
 * Hard-pins project ref to jyezfiehhfgnvhzzffxr; aborts before first write otherwise.
 */
import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";
import {
  runStage1bEvaluateGates,
  runStage1bPreviewCert,
  runStage1bScoreFixture,
  runStage1bSetup,
  type CertRunRequest,
} from "../_shared/stage1bCert/engine.ts";
import { assertOrchestratorPreviewUrl } from "../_shared/stage1bCert/previewPin.ts";
import { authorizePreviewCertRequest } from "../_shared/stage1bCert/previewCertAuth.ts";
import {
  CERT_RUNNER_VERSION,
  PREVIEW_CERT_PROJECT_REF,
} from "../_shared/stage1bCert/constants.ts";

const JSON_HEADERS = { ...corsHeaders, "Content-Type": "application/json" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!authorizePreviewCertRequest(req)) {
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

  let body: CertRunRequest & { probe_runtime_secrets?: boolean };
  try {
    body = await req.json() as CertRunRequest & { probe_runtime_secrets?: boolean };
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  if (body.probe_runtime_secrets === true) {
    try {
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
      const diagnostics = {
        AUTH_VALID: true,
        GEMINI_SECRET_PRESENT: readiness.GEMINI_API_KEY,
        CERT_SECRET_PRESENT: readiness.WA_STAGE1B_CERT_SECRET,
        MEDIA_HOST_CONFIG_PRESENT: Boolean(Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS")),
        SERVICE_ROLE_PRESENT: readiness.SUPABASE_SERVICE_ROLE_KEY,
        PREVIEW_REF_MATCH: (Deno.env.get("SUPABASE_URL") ?? "").includes(PREVIEW_CERT_PROJECT_REF),
        FUNCTION_VERSION: CERT_RUNNER_VERSION,
        PROBE_MODE: "in_process_worker",
        PROBE_STATUS: runtime.status,
        PROBE_ERROR: runtime.error,
      };
      return json({
        ok: runtime.configured,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        runtime_secret_readiness: readiness,
        diagnostics,
      }, runtime.configured ? 200 : 503);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return json({
        ok: false,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        error: message.slice(0, 200),
        diagnostics: {
          AUTH_VALID: true,
          GEMINI_SECRET_PRESENT: Boolean(Deno.env.get("GEMINI_API_KEY")),
          CERT_SECRET_PRESENT: Boolean(Deno.env.get("WA_STAGE1B_CERT_SECRET")),
          MEDIA_HOST_CONFIG_PRESENT: Boolean(Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS")),
          SERVICE_ROLE_PRESENT: Boolean(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")),
          PREVIEW_REF_MATCH: (Deno.env.get("SUPABASE_URL") ?? "").includes(PREVIEW_CERT_PROJECT_REF),
          FUNCTION_VERSION: CERT_RUNNER_VERSION,
          PROBE_MODE: "in_process_worker",
          PROBE_FAILED: true,
        },
      }, 503);
    }
  }

  try {
    if (body.phase === "setup") {
      const setup = await runStage1bSetup(body);
      return json({
        ok: true,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        phase: "setup",
        ...setup,
      });
    }

    if (body.phase === "fixture") {
      const result = await runStage1bScoreFixture(body);
      return json({
        ok: true,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        phase: "fixture",
        run_id: body.run_id,
        run_tag: body.run_tag,
        result,
      });
    }

    if (body.phase === "gates") {
      const report = await runStage1bEvaluateGates(body);
      const status = report.status === "COMPLETE" ? 200 : report.status === "FAILED" ? 422 : 503;
      return json({
        ok: report.status === "COMPLETE",
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        non_production: true,
        phase: "gates",
        report,
      }, status);
    }

    if (!Array.isArray(body.fixtures) || !body.fixtures.length) {
      return json({ ok: false, error: "fixtures_required" }, 400);
    }

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
