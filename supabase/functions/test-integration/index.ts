import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";

// Generic integration health probe. Never fakes success.
// Input: { integration_key: string }
// Output: { ok, message, details }

const FEATURE_FOR_INTEGRATION: Record<string, string> = {
  ai_image_studio: "ai_image_studio",
  ai_video_studio: "ai_video_studio",
  whatsapp_business_api: "whatsapp_business_api",
  barcode_label_app: "barcode_label_app",
  oasis_central_sync: "oasis_central_sync",
  payment_gateway: "payment_gateway",
  tally_invoice_sync: "tally_invoice_sync",
  printer_bridge: "printer_bridge",
  advanced_pdf_proposal: "advanced_pdf_proposal",
  bulk_pdf_import: "bulk_pdf_import",
};

const SECRET_KEYS: Record<string, string[]> = {
  ai_image_studio: ["LOVABLE_API_KEY"],
  ai_video_studio: ["LOVABLE_API_KEY"],
  whatsapp_business_api: ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID"],
  barcode_label_app: ["BARCODE_APP_URL"],
  oasis_central_sync: ["OASIS_CENTRAL_URL", "OASIS_CENTRAL_TOKEN"],
  payment_gateway: ["RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"],
  tally_invoice_sync: ["TALLY_BRIDGE_URL"],
  printer_bridge: ["PRINTER_BRIDGE_URL"],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const body = await req.json().catch(() => ({}));
    const integration_key = String(body?.integration_key ?? "").trim();
    if (!integration_key) {
      return json({ ok: false, message: "integration_key is required", details: {} }, 400);
    }

    // AuthN: must be owner/admin (use RPC to bypass RLS pitfalls)
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
    const userClient = createClient(supabaseUrl, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: userData } = await userClient.auth.getUser();
    if (!userData?.user) return json({ ok: false, message: "Not authenticated", details: {} }, 401);
    const { data: rpcRoles, error: rpcErr } = await userClient.rpc("get_current_user_roles");
    if (rpcErr) return json({ ok: false, message: "Role check failed: " + rpcErr.message, details: {} }, 500);
    const roleSet = new Set<string>((rpcRoles ?? []) as string[]);
    if (!roleSet.has("owner") && !roleSet.has("admin")) {
      return json({ ok: false, message: "Owner or admin role required", details: {} }, 403);
    }

    const required = SECRET_KEYS[integration_key] ?? [];
    const missing = required.filter((k) => !Deno.env.get(k));
    let result: { ok: boolean; message: string; details: any };
    if (required.length === 0) {
      result = {
        ok: false,
        message: "No automated test defined yet. Configure provider and credentials, then re-test.",
        details: { integration_key },
      };
    } else if (missing.length) {
      result = {
        ok: false,
        message: "Not configured",
        details: { missing_secrets: missing },
      };
    } else {
      result = {
        ok: false,
        message: "Credentials present but live connectivity test not implemented. Manual verification required.",
        details: { configured_secrets: required },
      };
    }

    // Service-role write to update last_tested_*
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(supabaseUrl, serviceKey);
    const featureKey = FEATURE_FOR_INTEGRATION[integration_key];
    const newStatus = result.ok ? "test_passed" : "error";
    await admin
      .from("integration_settings")
      .update({ status: newStatus, last_tested_at: new Date().toISOString(), last_test_result: result, secret_status: missing.length ? "missing" : "configured" })
      .eq("integration_key", integration_key);
    if (featureKey) {
      const featureStatus = result.ok ? "test_passed" : "error";
      await admin
        .from("feature_flags")
        .update({ last_tested_at: new Date().toISOString(), last_test_result: result.message })
        .eq("feature_key", featureKey);
      await admin.from("feature_activation_audit").insert({
        feature_key: featureKey,
        action: "test_connection",
        new_status: featureStatus,
        performed_by: userData.user.id,
        notes: result.message,
      });
    }

    return json(result, 200);
  } catch (e) {
    return json({ ok: false, message: (e as Error).message ?? "Unknown error", details: {} }, 500);
  }
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
