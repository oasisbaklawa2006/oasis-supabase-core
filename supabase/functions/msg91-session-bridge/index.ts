import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

type RequestBody = {
  mode?: string;
  accessToken?: string;
  phone?: string | null;
};

type LegacyVerifiedResponse = {
  ok?: boolean;
  type?: string;
  user_id?: string;
  email?: string;
  phone?: string;
  is_new?: boolean;
  token_hash?: string | null;
  error?: string;
  reason?: string;
};

type MintResult = { tokenHash: string } | { error: "session_token_mint_failed" };

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function fail(error: string, status: number): Response {
  return jsonResponse({ ok: false, error }, status);
}

async function verifyThroughLegacyMsg91(accessToken: string): Promise<LegacyVerifiedResponse | null> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return null;

  try {
    const response = await fetch(`${SUPABASE_URL}/functions/v1/msg91-otp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        apikey: SERVICE_ROLE_KEY,
      },
      // Deliberately do NOT forward the client-supplied phone. Production v72
      // otherwise gives request.phone precedence over the phone verified by MSG91.
      body: JSON.stringify({ mode: "verify_widget", accessToken }),
    });

    const payload = (await response.json().catch(() => null)) as LegacyVerifiedResponse | null;
    if (!response.ok || !payload) return null;
    return payload;
  } catch (error) {
    console.error("[msg91-session-bridge] upstream verification transport failed", error instanceof Error ? error.name : "unknown");
    return null;
  }
}

async function mintRedirectIndependentTokenHash(email: string): Promise<MintResult> {
  if (!supabaseAdmin) return { error: "session_token_mint_failed" };

  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) return { error: "session_token_mint_failed" };

    const properties = data.properties || {};
    if (typeof properties.hashed_token === "string" && properties.hashed_token) {
      return { tokenHash: properties.hashed_token };
    }

    const actionLink = typeof properties.action_link === "string" ? properties.action_link : "";
    const tokenMatch = actionLink.match(/token_hash=([^&]+)/) || actionLink.match(/[?#&]token=([^&]+)/);
    if (!tokenMatch) return { error: "session_token_mint_failed" };

    return { tokenHash: decodeURIComponent(tokenMatch[1]) };
  } catch (error) {
    console.error("[msg91-session-bridge] token mint failed", error instanceof Error ? error.name : "unknown");
    return { error: "session_token_mint_failed" };
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return fail("method_not_allowed", 405);
  if (!supabaseAdmin) return fail("auth_service_unavailable", 503);

  try {
    const body = (await req.json()) as RequestBody;
    if (body?.mode !== "verify_widget") return fail("unsupported_mode", 400);
    if (typeof body.accessToken !== "string" || !body.accessToken.trim()) {
      return fail("access_token_required", 400);
    }

    const verified = await verifyThroughLegacyMsg91(body.accessToken.trim());
    if (!verified || verified.ok !== true || verified.type !== "success") {
      return fail("provider_verification_failed", 401);
    }

    if (
      typeof verified.user_id !== "string" || !verified.user_id ||
      typeof verified.email !== "string" || !verified.email ||
      typeof verified.phone !== "string" || !verified.phone
    ) {
      return fail("verified_identity_unavailable", 502);
    }

    let tokenHash = typeof verified.token_hash === "string" && verified.token_hash
      ? verified.token_hash
      : null;

    if (!tokenHash) {
      const minted = await mintRedirectIndependentTokenHash(verified.email);
      if ("error" in minted) return fail(minted.error, 502);
      tokenHash = minted.tokenHash;
    }

    return jsonResponse({
      ok: true,
      type: "success",
      user_id: verified.user_id,
      phone: verified.phone,
      is_new: verified.is_new === true,
      token_hash: tokenHash,
    });
  } catch (error) {
    console.error("[msg91-session-bridge] fatal", error instanceof Error ? error.name : "unknown");
    return fail("internal_error", 500);
  }
});
