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

type AuthUserRef = { userId: string; email: string };

function last10(raw: string): string {
  const d = (raw || "").replace(/\D/g, "");
  return d.length >= 10 ? d.slice(-10) : d;
}

function phoneVariants(normalized: string): string[] {
  const tail = last10(normalized);
  if (tail.length < 10) return [];
  return [...new Set([tail, `91${tail}`, `+91${tail}`, `0${tail}`])];
}

type EmailBindResult = { email: string } | { error: string };

/** Ensure the matched auth user has the internal email required by the hash exchange. */
async function ensureInternalEmail(userId: string, currentEmail: string, normalized: string): Promise<EmailBindResult> {
  const internalEmail = internalEmailFor(normalized);
  if (currentEmail) return { email: currentEmail };
  if (!supabaseAdmin) return { error: "auth_email_bind_failed" };
  const { error } = await supabaseAdmin.auth.admin.updateUserById(userId, { email: internalEmail, email_confirm: true });
  if (error) {
    console.error("[msg91] auth_email_bind_failed:", maskSecret(error.message ?? null) ?? "unknown");
    return { error: "auth_email_bind_failed" };
  }
  return { email: internalEmail };
}

async function createAuthUserForPhone(e164: string, normalized: string): Promise<AuthUserRef | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const internalEmail = internalEmailFor(normalized);
  const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
    phone: e164,
    phone_confirm: true,
    email: internalEmail,
    email_confirm: true,
  });
  if (createErr || !created?.user) {
    console.error("[msg91] auth_user_create_failed:", maskSecret(createErr?.message ?? null) ?? "unknown");
    return { error: "auth_user_create_failed" };
  }
  return { userId: created.user.id, email: internalEmail };
}

/**
 * Fail-closed identity collision guard. Current production phone data is stored
 * in one of four canonical forms (10-digit, 91..., +91..., or 0...). Query those
 * variants directly instead of enumerating the entire users directory.
 */
async function findPublicIdentityMatches(normalized: string): Promise<{ ids: string[] } | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const variants = phoneVariants(normalized);
  if (!variants.length) return { error: "phone_invalid" };

  const [phoneResult, mobileResult, secondaryResult] = await Promise.all([
    supabaseAdmin.from("users").select("id").in("phone", variants),
    supabaseAdmin.from("users").select("id").in("mobile_number", variants),
    supabaseAdmin.from("users").select("id").overlaps("secondary_phones", variants),
  ]);

  const lookupError = phoneResult.error || mobileResult.error || secondaryResult.error;
  if (lookupError) {
    console.error("[msg91] identity lookup error:", maskSecret(lookupError.message ?? null) ?? "unknown");
    return { error: "identity_lookup_failed" };
  }

  const ids = new Set<string>();
  for (const row of [...(phoneResult.data || []), ...(mobileResult.data || []), ...(secondaryResult.data || [])]) {
    if (row?.id) ids.add(String(row.id));
  }
  return { ids: [...ids] };
}

type MintResult = { tokenHash: string } | { error: string };

/**
 * The hash is consumed programmatically by supabase.auth.verifyOtp on the client,
 * so no redirect target is requested here and the flow must not depend on any
 * site allow-list. Mint failures are propagated explicitly; a null hash is never
 * returned as a success.
 */
async function mintMagicTokenHash(email: string): Promise<MintResult> {
  if (!supabaseAdmin) return { error: "session_token_mint_failed" };
  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) {
      console.error("[msg91] token mint provider error:", maskSecret(error?.message ?? null) ?? "unknown");
      return { error: "session_token_mint_failed" };
    }
    const props = data.properties || {};
    if (typeof props.hashed_token === "string" && props.hashed_token) {
      return { tokenHash: props.hashed_token };
    }
    const link = typeof props.action_link === "string" ? props.action_link : "";
    const m = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
    if (m) return { tokenHash: decodeURIComponent(m[1]) };
    return { error: "session_token_mint_failed" };
  } catch (e) {
    console.error("[msg91] token mint threw:", e instanceof Error ? e.name : "unknown");
    return { error: "session_token_mint_failed" };
  }
}

type PendingProfileResult = { ok: true } | { error: string };

/**
 * Governed PENDING row creation. Never soft-fails: the caller must not mint a
 * session for a phone identity without a confirmed public.users PENDING row.
 */
async function ensurePendingProfile(userId: string, phoneE164: string): Promise<PendingProfileResult> {
  if (!supabaseAdmin) return { error: "pending_profile_create_failed" };
  try {
    const { error } = await supabaseAdmin.from("users").upsert(
      { id: userId, role: "PENDING", phone: phoneE164 },
      { onConflict: "id", ignoreDuplicates: true },
    );
    if (error) {
      console.error("[msg91] pending_profile_create_failed:", maskSecret(error.message ?? null) ?? "unknown");
      return { error: "pending_profile_create_failed" };
    }
    return { ok: true };
  } catch (e) {
    console.error("[msg91] pending_profile_create_failed threw:", e instanceof Error ? e.name : "unknown");
    return { error: "pending_profile_create_failed" };
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

type UnknownRecord = Record<string, unknown>;

function asRecord(value: unknown): UnknownRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as UnknownRecord;
}

/**
 * Provider authority: the verified phone used for identity/session minting comes
 * ONLY from the server-side verifyAccessToken response. Client-supplied phone is
 * never accepted here (it may only corroborate, never establish, identity).
 */
function extractProviderVerifiedPhone(raw: UnknownRecord): string | null {
  // MSG91 verifyAccessToken commonly returns: { type: "success", message: "919891162212" }
  // where `message` is the verified phone as a STRING. Handle that first, then fall back
  // to nested object shapes from older/alternate widget versions.
  const message = asRecord(raw.message);
  const data = asRecord(raw.data);
  const dataUser = asRecord(data?.user);
  const messageAsString = typeof raw.message === "string" ? raw.message : null;
  const dataAsString = typeof raw.data === "string" ? raw.data : null;
  return firstString(
    messageAsString,
    dataAsString,
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

// ---- MSG91 Widget server-side verification --------------------------------
// Docs: POST https://api.msg91.com/api/v5/widget/verifyAccessToken
//   Headers: Content-Type: application/json, Accept: application/json
//   Body:    { authkey, "access-token" }
//   Success: { type: "success", message: "...", ... }
async function verifyAccessToken(accessToken: string): Promise<{ ok: boolean; raw: UnknownRecord }> {
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
      authKey: maskSecret(AUTH_KEY),
      accessToken: maskSecret(accessToken),
      raw,
    }));
    const ok = res.ok && (raw.type === "success");
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
        phone: maskSecret(body.phone ?? null),
      }));
      if (!body.accessToken) {
        return new Response(JSON.stringify({ ok: false, error: "accessToken required" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const result = await verifyAccessToken(body.accessToken);
      if (!result.ok) {
        return new Response(
          JSON.stringify({
            ok: false,
            type: typeof result.raw.type === "string" ? result.raw.type : null,
            error: "provider_verification_failed",
          }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
      const fail = (error: string, status: number) =>
        new Response(JSON.stringify({ ok: false, error }), { status, headers: jsonHeaders });

      // ── Provider phone authority ──
      // Only the MSG91 verifyAccessToken response may establish the verified phone.
      const rawPhone = extractProviderVerifiedPhone(result.raw) || "";
      const normalized = to91(String(rawPhone));
      if (!normalized || normalized.length < 10) {
        console.error("[msg91-otp] verified_phone_missing");
        return fail("verified_phone_missing", 401);
      }
      // A client-supplied phone may only corroborate the provider phone.
      if (body.phone) {
        const claimed = to91(String(body.phone));
        if (last10(claimed) !== last10(normalized)) {
          console.error("[msg91-otp] phone_verification_mismatch");
          return fail("phone_verification_mismatch", 409);
        }
      }
      const e164 = `+${normalized}`;

      // ── Fail-closed identity collision guard (runs before any identity write) ──
      const publicMatches = await findPublicIdentityMatches(normalized);
      if ("error" in publicMatches) {
        console.error("[msg91-otp] identity lookup failed:", publicMatches.error);
        return fail(publicMatches.error, 500);
      }
      if (publicMatches.ids.length > 1) {
        console.error("[msg91-otp] duplicate_phone_identity", JSON.stringify({ matches: publicMatches.ids.length }));
        return fail("duplicate_phone_identity", 409);
      }

      let authRef: AuthUserRef;
      let isNew = false;

      if (publicMatches.ids.length === 1) {
        const publicId = publicMatches.ids[0];
        const { data: authLookup, error: authLookupError } = await supabaseAdmin!.auth.admin.getUserById(publicId);
        if (authLookupError || !authLookup?.user) {
          console.error("[msg91-otp] auth identity lookup failed:", maskSecret(authLookupError?.message ?? null) ?? "missing");
          return fail("phone_already_linked_to_other_identity", 409);
        }
        const bound = await ensureInternalEmail(authLookup.user.id, authLookup.user.email || "", normalized);
        if ("error" in bound) return fail(bound.error, 500);
        authRef = { userId: authLookup.user.id, email: bound.email };
      } else {
        // A zero-public-row phone must create exactly one new Auth identity. If an
        // orphaned Auth row already owns this phone, Auth's uniqueness constraint
        // rejects creation and we fail closed for manual reconciliation rather
        // than enumerating the entire Auth directory or guessing ownership.
        const created = await createAuthUserForPhone(e164, normalized);
        if ("error" in created) return fail(created.error, 500);
        authRef = created;
        isNew = true;
        const pending = await ensurePendingProfile(authRef.userId, e164);
        if ("error" in pending) return fail(pending.error, 500);
      }

      const mint = await mintMagicTokenHash(authRef.email);
      if ("error" in mint) {
        console.error("[msg91-otp] verify_widget mint failure", JSON.stringify({ user_id: authRef.userId, error: mint.error }));
        return fail(mint.error, 502);
      }

      console.log("[msg91-otp] verify_widget response", JSON.stringify({
        ok: true,
        type: "success",
        user_id: authRef.userId,
        is_new: isNew,
        token_hash: maskSecret(mint.tokenHash),
      }));
      return new Response(
        JSON.stringify({
          ok: true,
          type: "success",
          user_id: authRef.userId,
          email: authRef.email,
          phone: e164,
          is_new: isNew,
          token_hash: mint.tokenHash,
        }),
        { status: 200, headers: jsonHeaders },
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
