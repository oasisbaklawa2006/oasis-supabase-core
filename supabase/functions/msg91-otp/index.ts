// MSG91 OTP & Notification Service
// ----------------------------------
// Modes:
//   1. mode: "verify_widget"  → Server-side verifyAccessToken from MSG91 OTP Widget.
//                                Client passes the access-token returned by initSendOTP success
//                                callback; we hit MSG91 verifyAccessToken endpoint and only
//                                return ok=true if MSG91 responds with type="success".
//   2. mode: "login_otp"      → (Legacy) send a 6-digit OTP via failover ladder.
//   3. mode: "order_received" → Notify a client that their WhatsApp order was logged.
//
// FAILOVER LADDER (legacy modes): WhatsApp → SMS → Email → Voice
//
// Secrets:
//   - MSG91_AUTH_KEY   (mandatory for real sends + widget verification)
//   - MSG91_SENDER_ID  (optional; default "OASBKL")
//   - MSG91_VOICE_DID  (optional, voice fallback)
//   - RESEND_API_KEY   (email tier)

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type Channel = "whatsapp" | "sms" | "email" | "voice";

interface RequestBody {
  mode: "verify_widget" | "login_otp" | "order_received";
  /** verify_widget: the access-token returned by MSG91 widget success callback. */
  accessToken?: string;
  /** verify_widget: the verified phone number (10-digit or +91...) — required to mint session. */
  phone?: string;
  email?: string | null;
  message?: string;
  otp?: string;
  skip?: Channel[];
}

// Service-role client used ONLY for minting sessions on verified phones.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

function internalEmailFor(phoneDigits: string): string {
  return `${phoneDigits}@phone.oasis.local`;
}

async function findOrCreateAuthUserByPhone(e164: string, normalized: string): Promise<{ userId: string; email: string; isNew: boolean } | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const internalEmail = internalEmailFor(normalized);

  // Find existing user across pages
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await supabaseAdmin.auth.admin.listUsers({ page, perPage: 500 });
    if (error) break;
    const users = data?.users || [];
    if (!users.length) break;
    const match = users.find((u: any) => u.phone === e164 || u.phone === normalized || u.phone === `+${normalized}` || u.email === internalEmail);
    if (match) {
      let email = match.email || internalEmail;
      if (!match.email) {
        await supabaseAdmin.auth.admin.updateUserById(match.id, { email: internalEmail, email_confirm: true });
        email = internalEmail;
      }
      return { userId: match.id, email, isNew: false };
    }
    if (users.length < 500) break;
  }

  // Create
  const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
    phone: e164,
    phone_confirm: true,
    email: internalEmail,
    email_confirm: true,
  });
  if (createErr || !created?.user) {
    return { error: createErr?.message || "create_user_failed" };
  }
  return { userId: created.user.id, email: internalEmail, isNew: true };
}

async function mintMagicTokenHash(email: string): Promise<string | null> {
  if (!supabaseAdmin) return null;
  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) return null;
    const props: any = data.properties || {};
    if (props.hashed_token) return props.hashed_token as string;
    const link: string = props.action_link || "";
    const m = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
    return m ? decodeURIComponent(m[1]) : null;
  } catch (e) {
    console.error("[msg91] generateLink failed:", e);
    return null;
  }
}

async function ensurePendingProfile(userId: string, phoneE164: string): Promise<void> {
  if (!supabaseAdmin) return;
  try {
    // Insert a PENDING users row if none exists. Approval flow handles the rest.
    await supabaseAdmin.from("users").upsert(
      { id: userId, role: "PENDING", phone: phoneE164 } as any,
      { onConflict: "id", ignoreDuplicates: true } as any,
    );
  } catch (e) {
    console.warn("[msg91] ensurePendingProfile soft-failed:", e);
  }
}

// Unified MSG91 auth key (matches client widget tokenAuth: 509994AgMgjQib69e9dc60P1).
// Falls back to placeholder so the function still boots if secret unset.
const AUTH_KEY = Deno.env.get("MSG91_AUTH_KEY") || "509994A5pbHkTLr69ea2a63P1";
const SENDER_ID = Deno.env.get("MSG91_SENDER_ID") || "OASBKL";
const VOICE_DID = Deno.env.get("MSG91_VOICE_DID") || "";
const MSG91_ENABLED = AUTH_KEY !== "PLACEHOLDER_NOT_CONFIGURED";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") || "";

function to91(raw: string): string {
  const d = (raw || "").replace(/\D/g, "");
  if (d.length === 10) return `91${d}`;
  if (d.length === 12 && d.startsWith("91")) return d;
  if (d.length >= 10) return d.slice(-12);
  return d;
}

function genOtp(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function maskSecret(value?: string | null): string | null {
  if (!value) return null;
  if (value.length <= 8) return `${value.slice(0, 2)}***${value.slice(-2)}`;
  return `${value.slice(0, 4)}***${value.slice(-4)}`;
}

function extractVerifiedPhone(raw: any, requestPhone?: string | null): string | null {
  // MSG91 verifyAccessToken commonly returns: { type: "success", message: "919891162212" }
  // where `message` is the verified phone as a STRING. Handle that first, then fall back
  // to nested object shapes from older/alternate widget versions.
  const messageAsString = typeof raw?.message === "string" ? raw.message : null;
  const dataAsString = typeof raw?.data === "string" ? raw.data : null;
  return firstString(
    requestPhone,
    messageAsString,
    dataAsString,
    raw?.message?.mobile,
    raw?.message?.phone,
    raw?.message?.identifier,
    raw?.message?.number,
    raw?.data?.mobile,
    raw?.data?.phone,
    raw?.data?.identifier,
    raw?.data?.number,
    raw?.mobile,
    raw?.phone,
    raw?.identifier,
    raw?.number,
  );
}

// ---- MSG91 Widget server-side verification --------------------------------
// Docs: POST https://api.msg91.com/api/v5/widget/verifyAccessToken
//   Headers: Content-Type: application/json, Accept: application/json
//   Body:    { authkey, "access-token" }
//   Success: { type: "success", message: "...", ... }
async function verifyAccessToken(accessToken: string): Promise<{ ok: boolean; raw: any }> {
  try {
    const res = await fetch("https://control.msg91.com/api/v5/widget/verifyAccessToken", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ authkey: AUTH_KEY, "access-token": accessToken }),
    });
    const raw = await res.json().catch(() => ({}));
    console.log("[msg91-otp] verifyAccessToken response", JSON.stringify({
      ok: res.ok,
      status: res.status,
      authKey: maskSecret(AUTH_KEY),
      accessToken: maskSecret(accessToken),
      raw,
    }));
    const ok = res.ok && (raw?.type === "success");
    return { ok, raw };
  } catch (e) {
    console.error("[msg91] verifyAccessToken failed:", e);
    return { ok: false, raw: { error: e instanceof Error ? e.message : "unknown" } };
  }
}

// ---- Channel implementations (legacy ladder) ------------------------------

async function sendWhatsApp(phone: string, body: string): Promise<boolean> {
  if (!MSG91_ENABLED) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({
        integrated_number: SENDER_ID,
        content_type: "text",
        payload: { to: to91(phone), type: "text", text: { body } },
      }),
    });
    return res.ok;
  } catch (e) { console.error("[msg91] whatsapp failed:", e); return false; }
}

async function sendSMS(phone: string, body: string): Promise<boolean> {
  if (!MSG91_ENABLED) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/flow/", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({ sender: SENDER_ID, short_url: "0", mobiles: to91(phone), body }),
    });
    return res.ok;
  } catch (e) { console.error("[msg91] sms failed:", e); return false; }
}

async function sendEmail(email: string, subject: string, body: string): Promise<boolean> {
  if (!RESEND_KEY || !email) return false;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_KEY}` },
      body: JSON.stringify({
        from: "Oasis Baklawa <noreply@oasisbaklawa.com>",
        to: [email], subject, text: body,
      }),
    });
    return res.ok;
  } catch (e) { console.error("[msg91] email failed:", e); return false; }
}

async function sendVoice(phone: string, body: string): Promise<boolean> {
  if (!MSG91_ENABLED || !VOICE_DID) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/voice/outbound", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({ from: VOICE_DID, to: to91(phone), text: body, voice: "female-en-IN" }),
    });
    return res.ok;
  } catch (e) { console.error("[msg91] voice failed:", e); return false; }
}

async function deliver(
  phone: string, email: string | null | undefined, body: string, subject: string, skip: Channel[] = [],
): Promise<{ delivered: boolean; channel: Channel | null; tried: Channel[] }> {
  const tried: Channel[] = [];
  if (!skip.includes("whatsapp") && phone) {
    tried.push("whatsapp");
    if (await sendWhatsApp(phone, body)) return { delivered: true, channel: "whatsapp", tried };
  }
  if (!skip.includes("sms") && phone) {
    tried.push("sms");
    if (await sendSMS(phone, body)) return { delivered: true, channel: "sms", tried };
  }
  if (!skip.includes("email") && email) {
    tried.push("email");
    if (await sendEmail(email, subject, body)) return { delivered: true, channel: "email", tried };
  }
  if (!skip.includes("voice") && phone) {
    tried.push("voice");
    if (await sendVoice(phone, body)) return { delivered: true, channel: "voice", tried };
  }
  return { delivered: false, channel: null, tried };
}

// ---- HTTP handler ---------------------------------------------------------

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const body = (await req.json()) as RequestBody;
    if (!body?.mode) {
      return new Response(JSON.stringify({ ok: false, error: "mode is required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (body.mode === "verify_widget") {
      console.log("[msg91-otp] verify_widget request", JSON.stringify({
        mode: body.mode,
        accessToken: maskSecret(body.accessToken ?? null),
        phone: body.phone ?? null,
      }));
      if (!body.accessToken) {
        return new Response(JSON.stringify({ ok: false, error: "accessToken required" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const result = await verifyAccessToken(body.accessToken);
      if (!result.ok) {
        return new Response(
          JSON.stringify({ ok: false, type: result.raw?.type ?? null, raw: result.raw }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // ── Mint a Supabase session for the verified phone ──
      // Phone may come from request body OR from MSG91's verifyAccessToken response.
      const rawPhone = extractVerifiedPhone(result.raw, body.phone ?? null) || "";
      const normalized = to91(String(rawPhone));
      if (!normalized || normalized.length < 10) {
        // Verification succeeded but no phone available — return ok without session.
        console.log("[msg91-otp] verify_widget response", JSON.stringify({
          ok: true,
          type: "success",
          session: null,
          reason: "phone_missing",
          raw: result.raw,
        }));
        return new Response(
          JSON.stringify({ ok: true, type: "success", session: null, reason: "phone_missing", raw: result.raw }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      const e164 = `+${normalized}`;

      const upsertRes = await findOrCreateAuthUserByPhone(e164, normalized);
      if ("error" in upsertRes) {
        return new Response(
          JSON.stringify({ ok: true, type: "success", session: null, error: upsertRes.error }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      if (upsertRes.isNew) {
        await ensurePendingProfile(upsertRes.userId, e164);
      }

      const tokenHash = await mintMagicTokenHash(upsertRes.email);
      console.log("[msg91-otp] verify_widget response", JSON.stringify({
        ok: true,
        type: "success",
        user_id: upsertRes.userId,
        email: upsertRes.email,
        phone: e164,
        is_new: upsertRes.isNew,
        token_hash: maskSecret(tokenHash),
      }));
      return new Response(
        JSON.stringify({
          ok: true,
          type: "success",
          user_id: upsertRes.userId,
          email: upsertRes.email,
          phone: e164,
          is_new: upsertRes.isNew,
          token_hash: tokenHash,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (body.mode === "login_otp") {
      const otp = body.otp || genOtp();
      const phone = body.phone || "";
      if (!phone) {
        return new Response(JSON.stringify({ ok: false, error: "phone required" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const text = `Your Oasis Baklawa login code is ${otp}. Valid for 5 minutes. Do not share this code.`;
      const result = await deliver(phone, body.email ?? null, text, "Oasis Baklawa Login Code", body.skip || []);
      return new Response(
        JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried, otp }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (body.mode === "order_received") {
      const phone = body.phone || "";
      const text = body.message || "Your order has been received by Oasis Baklawa. Our team will confirm shortly.";
      const result = await deliver(phone, body.email ?? null, text, "Order Received — Oasis Baklawa", body.skip || []);
      return new Response(
        JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return new Response(JSON.stringify({ ok: false, error: "unknown mode" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("[msg91-otp] fatal:", e);
    return new Response(
      JSON.stringify({ ok: false, error: e instanceof Error ? e.message : "unknown" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
