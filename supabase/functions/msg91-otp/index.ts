// MSG91 verified-widget authentication endpoint
// Legacy outbound modes (login_otp, order_received) are disabled before provider calls.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { rejectLegacyOutboundMode } from "./legacy-outbound-policy.mjs";
import { canonicalIndianPhone, phoneEquals } from "./strict-phone-match.mjs";
import { exchangeVerifiedPhone } from "./identity-flow.mjs";

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


type MintResult = { tokenHash: string } | { error: string };

async function mintMagicTokenHash(email: string): Promise<MintResult> {
  if (!supabaseAdmin) return { error: "session_token_mint_failed" };
  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({ type: "magiclink", email });
    if (error || !data) {
      console.error("[msg91] token mint provider error:", maskSecret(error?.message ?? null) ?? "unknown");
      return { error: "session_token_mint_failed" };
    }
    const props = data.properties || {};
    if (typeof props.hashed_token === "string" && props.hashed_token) return { tokenHash: props.hashed_token };
    const link = typeof props.action_link === "string" ? props.action_link : "";
    const m = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
    if (m) return { tokenHash: decodeURIComponent(m[1]) };
    return { error: "session_token_mint_failed" };
  } catch (e) {
    console.error("[msg91] token mint threw:", e instanceof Error ? e.name : "unknown");
    return { error: "session_token_mint_failed" };
  }
}


const AUTH_KEY = (Deno.env.get("MSG91_AUTH_KEY") || "").trim();

function to91(raw: string): string {
  const d = (raw || "").replace(/\D/g, "");
  if (d.length === 10) return `91${d}`;
  if (d.length === 12 && d.startsWith("91")) return d;
  if (d.length >= 10) return d.slice(-12);
  return d;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) if (typeof value === "string" && value.trim()) return value.trim();
  return null;
}

function maskSecret(value?: string | null): string | null {
  if (!value) return null;
  if (value.length <= 8) return `${value.slice(0, 2)}***${value.slice(-2)}`;
  return `${value.slice(0, 4)}***${value.slice(-4)}`;
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

async function verifyAccessToken(accessToken: string): Promise<{ ok: boolean; raw: UnknownRecord }> {
  if (!AUTH_KEY) return { ok: false, raw: { error: "auth_key_unavailable" } };
  try {
    const res = await fetch("https://control.msg91.com/api/v5/widget/verifyAccessToken", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ authkey: AUTH_KEY, "access-token": accessToken }),
    });
    const raw = (await res.json().catch(() => ({}))) as UnknownRecord;
    console.log("[msg91-otp] verifyAccessToken response", JSON.stringify({
      ok: res.ok,
      status: res.status,
      type: typeof raw.type === "string" ? raw.type : "unknown",
    }));
    return { ok: res.ok && raw.type === "success", raw };
  } catch (e) {
    console.error("[msg91] verifyAccessToken failed:", e);
    return { ok: false, raw: { error: e instanceof Error ? e.message : "unknown" } };
  }
}

// Database-authoritative identity exchange (see identity-flow.mjs and migration
// 20261110150000_msg91_identity_resolution_authority_v1). Auth recovery is an indexed
// deterministic-email lookup inside the database RPC, never an Auth user-list scan.
function exchangeDeps() {
  const admin = supabaseAdmin!;
  return {
    rpc: (name: string, args: Record<string, unknown>) => admin.rpc(name, args),
    getAuthUserById: (id: string) => admin.auth.admin.getUserById(id),
    createAuthUser: (attrs: Record<string, unknown>) => admin.auth.admin.createUser(attrs as never),
    bindInternalEmail: (id: string, email: string) => admin.auth.admin.updateUserById(id, { email, email_confirm: true }),
    mintTokenHash: mintMagicTokenHash,
    log: (message: string) => console.error("[msg91]", message),
  };
}

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

      const exchanged = await exchangeVerifiedPhone(exchangeDeps(), normalized);
      return new Response(JSON.stringify(exchanged.body), { status: exchanged.status, headers: jsonHeaders });
    }

    return new Response(JSON.stringify({ ok: false, error: "unknown mode" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[msg91-otp] fatal:", e instanceof Error ? e.name : "unknown");
    return new Response(JSON.stringify({ ok: false, error: "internal_error" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
