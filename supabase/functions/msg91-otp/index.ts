// MSG91 verified-widget authentication endpoint
// Legacy outbound modes (login_otp, order_received) are disabled before provider calls.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { rejectLegacyOutboundMode } from "./legacy-outbound-policy.mjs";
import { canonicalIndianPhone, phoneEquals } from "./strict-phone-match.mjs";
import { exchangeVerifiedPhone } from "./identity-flow.mjs";
import { createExchangeDeps } from "./exchange-deps.mjs";
import { verifyProviderAccessToken } from "./provider-verify.mjs";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface RequestBody {
  mode: "verify_widget" | "login_otp" | "order_received";
  accessToken?: string;
  phone?: string;
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;


const AUTH_KEY = (Deno.env.get("MSG91_AUTH_KEY") || "").trim();

function firstString(...values: unknown[]): string | null {
  for (const value of values) if (typeof value === "string" && value.trim()) return value.trim();
  return null;
}

type UnknownRecord = Record<string, unknown>;
function asRecord(value: unknown): UnknownRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as UnknownRecord;
}

function extractProviderVerifiedPhone(raw: UnknownRecord): string | null {
  const message = asRecord(raw.message);
  const data = asRecord(raw.data);
  const dataUser = asRecord(data?.user);
  return firstString(
    typeof raw.message === "string" ? raw.message : null,
    typeof raw.data === "string" ? raw.data : null,
    message?.mobile,
    message?.phone,
    message?.identifier,
    message?.number,
    data?.mobile,
    data?.phone,
    data?.identifier,
    data?.number,
    raw.mobile,
    raw.phone,
    raw.identifier,
    raw.number,
    dataUser?.mobile,
    dataUser?.phone,
  );
}

function verifyAccessToken(accessToken: string): Promise<{ ok: boolean; raw: UnknownRecord }> {
  return verifyProviderAccessToken({
    authKey: AUTH_KEY,
    accessToken,
    log: (entry: unknown) => console.log("[msg91-otp] verifyAccessToken", JSON.stringify(entry)),
  });
}

// Database-authoritative identity exchange (see identity-flow.mjs and migration
// 20261110150000_msg91_identity_resolution_authority_v1). Auth recovery is an indexed
// deterministic-email lookup inside the database RPC, never an Auth user-list scan.
const logDiagnostic = (message: string) => console.error("[msg91]", message);

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  try {
    const body = (await req.json()) as RequestBody;
    if (!body?.mode) return new Response(JSON.stringify({ ok: false, error: "mode is required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });

    const legacyDenied = rejectLegacyOutboundMode(body.mode, corsHeaders);
    if (legacyDenied) return legacyDenied;

    if (body.mode === "verify_widget") {
      if (!body.accessToken) return new Response(JSON.stringify({ ok: false, error: "accessToken required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      const result = await verifyAccessToken(body.accessToken);
      if (!result.ok) return new Response(JSON.stringify({ ok: false, type: typeof result.raw.type === "string" ? result.raw.type : null, error: "provider_verification_failed" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });

      const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
      const fail = (error: string, status: number) => new Response(JSON.stringify({ ok: false, error }), { status, headers: jsonHeaders });
      const rawPhone = extractProviderVerifiedPhone(result.raw) || "";
      const normalized = canonicalIndianPhone(String(rawPhone));
      if (!normalized) return fail("verified_phone_missing", 401);
      if (body.phone && !phoneEquals(String(body.phone), normalized)) return fail("phone_verification_mismatch", 409);
      if (!supabaseAdmin) return fail("service_role_unavailable", 500);

      const exchanged = await exchangeVerifiedPhone(createExchangeDeps(supabaseAdmin, logDiagnostic), normalized);
      return new Response(JSON.stringify(exchanged.body), { status: exchanged.status, headers: jsonHeaders });
    }

    return new Response(JSON.stringify({ ok: false, error: "unknown mode" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[msg91-otp] fatal:", e instanceof Error ? e.name : "unknown");
    return new Response(JSON.stringify({ ok: false, error: "internal_error" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
