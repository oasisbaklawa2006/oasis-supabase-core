import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  corsHeaders,
  extractTokenHashFromGenerateLink,
  fail,
  jsonResponse,
  parseRequestBody,
  resolveBridgeSession,
  sanitizeBridgeResponseBody,
  validateBridgeRequest,
} from "../_shared/msg91SessionBridge.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

async function mintRedirectIndependentTokenHash(email: string): Promise<string | null> {
  if (!supabaseAdmin) return null;

  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) return null;
    return extractTokenHashFromGenerateLink(data);
  } catch (error) {
    console.error(
      "[msg91-session-bridge] token mint failed",
      error instanceof Error ? error.name : "unknown",
    );
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return fail("method_not_allowed", 405);
  if (!supabaseAdmin) return fail("auth_service_unavailable", 503);

  try {
    const body = parseRequestBody(await req.json());
    const validated = validateBridgeRequest(body);
    if ("error" in validated) {
      return fail(validated.error, validated.error === "unsupported_mode" ? 400 : 400);
    }

    const result = await resolveBridgeSession(
      {
        supabaseUrl: SUPABASE_URL,
        serviceRoleKey: SERVICE_ROLE_KEY,
        mintTokenHash: mintRedirectIndependentTokenHash,
      },
      validated.accessToken,
    );

    if (!result.ok) {
      const status = result.error === "provider_verification_failed"
        ? 401
        : result.error === "verified_identity_unavailable" ||
            result.error === "session_token_mint_failed"
        ? 502
        : 500;
      return fail(result.error, status);
    }

    return jsonResponse(sanitizeBridgeResponseBody(result));
  } catch (error) {
    console.error(
      "[msg91-session-bridge] fatal",
      error instanceof Error ? error.name : "unknown",
    );
    return fail("internal_error", 500);
  }
});
