// MSG91 OTP & Notification Service
// ----------------------------------
// Modes:
//   1. verify_widget  -> verify an MSG91 Widget access-token server-side, then
//                        mint the Supabase session handoff for the verified phone.
//   2. login_otp      -> legacy OTP delivery via the notification failover ladder.
//   3. order_received -> order-received notification delivery.
//
// Production security invariants for verify_widget:
//   - MSG91_AUTH_KEY must come from the Edge Runtime secret store.
//   - the provider-verified phone is the only identity authority.
//   - raw provider payloads, access tokens, phones and auth user IDs are not logged.
//   - durable rate/replay RPCs must admit the request before identity/session work.
//   - no success response is returned without a usable token_hash.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

type Channel = "whatsapp" | "sms" | "email" | "voice";
type UnknownRecord = Record<string, unknown>;
type AuthUserRef = { userId: string; email: string };
type GuardReply = { ok?: boolean; reason?: string };

interface RequestBody {
  mode: "verify_widget" | "login_otp" | "order_received";
  accessToken?: string;
  phone?: string;
  email?: string | null;
  message?: string;
  skip?: Channel[];
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")?.trim() || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() || "";
const AUTH_KEY = Deno.env.get("MSG91_AUTH_KEY")?.trim() || "";
const SENDER_ID = Deno.env.get("MSG91_SENDER_ID")?.trim() || "OASBKL";
const VOICE_DID = Deno.env.get("MSG91_VOICE_DID")?.trim() || "";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY")?.trim() || "";
const MSG91_ENABLED = AUTH_KEY.length > 0;

const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

function errorName(error: unknown): string {
  return error instanceof Error && error.name ? error.name : "unknown";
}

function providerErrorCode(error: unknown): string {
  if (error && typeof error === "object" && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code) return code;
  }
  return "unknown";
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function asRecord(value: unknown): UnknownRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as UnknownRecord;
}

function last10(raw: string): string {
  const digits = (raw || "").replace(/\D/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

function to91(raw: string): string {
  const digits = (raw || "").replace(/\D/g, "");
  if (digits.length === 10) return `91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return digits;
  if (digits.length >= 10) return digits.slice(-12);
  return digits;
}

function phoneVariants(normalized: string): string[] {
  const tail = last10(normalized);
  if (tail.length !== 10) return [];
  return [...new Set([tail, `91${tail}`, `+91${tail}`, `0${tail}`])];
}

function internalEmailFor(phoneDigits: string): string {
  return `${phoneDigits}@phone.oasis.local`;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function trustedRequestOrigin(req: Request): string | null {
  const cloudflare = req.headers.get("cf-connecting-ip")?.trim();
  if (cloudflare) return cloudflare;
  const realIp = req.headers.get("x-real-ip")?.trim();
  if (realIp) return realIp;
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return forwarded || null;
}

function jsonFailure(error: string, status: number): Response {
  return new Response(JSON.stringify({ ok: false, error }), { status, headers: jsonHeaders });
}

async function admitVerificationAttempt(req: Request): Promise<{ ipDigest: string } | { error: string; status: number }> {
  if (!supabaseAdmin) return { error: "security_guard_unavailable", status: 503 };
  const origin = trustedRequestOrigin(req);
  if (!origin) return { error: "request_origin_unavailable", status: 503 };
  const ipDigest = await sha256Hex(origin);
  const { data, error } = await supabaseAdmin.rpc("check_msg91_widget_attempt_v1", {
    p_ip_digest: ipDigest,
  });
  if (error) {
    console.error("[msg91-otp] attempt guard RPC failed", providerErrorCode(error));
    return { error: "security_guard_unavailable", status: 503 };
  }
  const reply = (data || {}) as GuardReply;
  if (reply.ok !== true) {
    return { error: reply.reason === "rate_limited" ? "rate_limited" : "security_guard_rejected", status: 429 };
  }
  return { ipDigest };
}

async function claimVerifiedToken(
  accessToken: string,
  normalizedPhone: string,
  ipDigest: string,
): Promise<{ ok: true } | { error: string; status: number }> {
  if (!supabaseAdmin) return { error: "security_guard_unavailable", status: 503 };
  const [tokenDigest, phoneDigest] = await Promise.all([
    sha256Hex(accessToken),
    sha256Hex(last10(normalizedPhone)),
  ]);
  const { data, error } = await supabaseAdmin.rpc("claim_msg91_widget_token_v1", {
    p_token_digest: tokenDigest,
    p_phone_digest: phoneDigest,
    p_ip_digest: ipDigest,
  });
  if (error) {
    console.error("[msg91-otp] token guard RPC failed", providerErrorCode(error));
    return { error: "security_guard_unavailable", status: 503 };
  }
  const reply = (data || {}) as GuardReply;
  if (reply.ok === true) return { ok: true };
  if (reply.reason === "access_token_replayed") return { error: "access_token_replayed", status: 409 };
  if (reply.reason === "rate_limited") return { error: "rate_limited", status: 429 };
  return { error: "security_guard_rejected", status: 409 };
}

function extractProviderVerifiedPhone(raw: UnknownRecord): string | null {
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

type VerifyAccessTokenResult = {
  ok: boolean;
  type: string | null;
  verifiedPhone: string | null;
};

async function verifyAccessToken(accessToken: string): Promise<VerifyAccessTokenResult> {
  try {
    const res = await fetch("https://control.msg91.com/api/v5/widget/verifyAccessToken", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ authkey: AUTH_KEY, "access-token": accessToken }),
    });
    const raw = (await res.json().catch(() => ({}))) as UnknownRecord;
    const type = typeof raw.type === "string" ? raw.type : null;
    const ok = res.ok && type === "success";
    console.log("[msg91-otp] provider verification", JSON.stringify({ ok, status: res.status, type }));
    return {
      ok,
      type,
      verifiedPhone: ok ? extractProviderVerifiedPhone(raw) : null,
    };
  } catch (error) {
    console.error("[msg91-otp] provider verification failed", errorName(error));
    return { ok: false, type: null, verifiedPhone: null };
  }
}

type EmailBindResult = { email: string } | { error: string };

async function ensureInternalEmail(userId: string, currentEmail: string, normalized: string): Promise<EmailBindResult> {
  const internalEmail = internalEmailFor(normalized);
  if (currentEmail) return { email: currentEmail };
  if (!supabaseAdmin) return { error: "auth_email_bind_failed" };
  const { error } = await supabaseAdmin.auth.admin.updateUserById(userId, {
    email: internalEmail,
    email_confirm: true,
  });
  if (error) {
    console.error("[msg91-otp] auth email bind failed", providerErrorCode(error));
    return { error: "auth_email_bind_failed" };
  }
  return { email: internalEmail };
}

async function createAuthUserForPhone(e164: string, normalized: string): Promise<AuthUserRef | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const internalEmail = internalEmailFor(normalized);
  const { data: created, error } = await supabaseAdmin.auth.admin.createUser({
    phone: e164,
    phone_confirm: true,
    email: internalEmail,
    email_confirm: true,
  });
  if (error || !created?.user) {
    console.error("[msg91-otp] auth user create failed", providerErrorCode(error));
    return { error: "auth_user_create_failed" };
  }
  return { userId: created.user.id, email: internalEmail };
}

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
    console.error("[msg91-otp] identity lookup failed", providerErrorCode(lookupError));
    return { error: "identity_lookup_failed" };
  }

  const ids = new Set<string>();
  for (const row of [...(phoneResult.data || []), ...(mobileResult.data || []), ...(secondaryResult.data || [])]) {
    if (row?.id) ids.add(String(row.id));
  }
  return { ids: [...ids] };
}

type MintResult = { tokenHash: string } | { error: string };

async function mintMagicTokenHash(email: string): Promise<MintResult> {
  if (!supabaseAdmin) return { error: "session_token_mint_failed" };
  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) {
      console.error("[msg91-otp] session token mint failed", providerErrorCode(error));
      return { error: "session_token_mint_failed" };
    }
    const props = data.properties || {};
    if (typeof props.hashed_token === "string" && props.hashed_token) {
      return { tokenHash: props.hashed_token };
    }
    const link = typeof props.action_link === "string" ? props.action_link : "";
    const match = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
    if (match) return { tokenHash: decodeURIComponent(match[1]) };
    return { error: "session_token_mint_failed" };
  } catch (error) {
    console.error("[msg91-otp] session token mint threw", errorName(error));
    return { error: "session_token_mint_failed" };
  }
}

type PendingProfileResult = { ok: true } | { error: string };

async function ensurePendingProfile(userId: string, phoneE164: string): Promise<PendingProfileResult> {
  if (!supabaseAdmin) return { error: "pending_profile_create_failed" };
  try {
    const { error } = await supabaseAdmin.from("users").upsert(
      { id: userId, role: "PENDING", phone: phoneE164 },
      { onConflict: "id", ignoreDuplicates: true },
    );
    if (error) {
      console.error("[msg91-otp] pending profile create failed", providerErrorCode(error));
      return { error: "pending_profile_create_failed" };
    }
    return { ok: true };
  } catch (error) {
    console.error("[msg91-otp] pending profile create threw", errorName(error));
    return { error: "pending_profile_create_failed" };
  }
}

function genOtp(): string {
  const range = 900000;
  const upperBound = Math.floor(0x100000000 / range) * range;
  const buffer = new Uint32Array(1);
  let value = upperBound;
  while (value >= upperBound) {
    crypto.getRandomValues(buffer);
    value = buffer[0];
  }
  return String(100000 + (value % range));
}

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
  } catch (error) {
    console.error("[msg91-otp] whatsapp delivery failed", errorName(error));
    return false;
  }
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
  } catch (error) {
    console.error("[msg91-otp] sms delivery failed", errorName(error));
    return false;
  }
}

async function sendEmail(email: string, subject: string, body: string): Promise<boolean> {
  if (!RESEND_KEY || !email) return false;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_KEY}` },
      body: JSON.stringify({
        from: "Oasis Baklawa <noreply@oasisbaklawa.com>",
        to: [email],
        subject,
        text: body,
      }),
    });
    return res.ok;
  } catch (error) {
    console.error("[msg91-otp] email delivery failed", errorName(error));
    return false;
  }
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
  } catch (error) {
    console.error("[msg91-otp] voice delivery failed", errorName(error));
    return false;
  }
}

async function deliver(
  phone: string,
  email: string | null | undefined,
  body: string,
  subject: string,
  skip: Channel[] = [],
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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const body = (await req.json()) as RequestBody;
    if (!body?.mode) return jsonFailure("mode is required", 400);

    if (body.mode === "verify_widget") {
      if (!body.accessToken) return jsonFailure("accessToken required", 400);
      if (!MSG91_ENABLED) return jsonFailure("provider_configuration_unavailable", 503);
      if (!supabaseAdmin) return jsonFailure("service_configuration_unavailable", 503);

      // Persistent per-origin guard runs before the external provider call.
      const attempt = await admitVerificationAttempt(req);
      if ("error" in attempt) return jsonFailure(attempt.error, attempt.status);

      const result = await verifyAccessToken(body.accessToken);
      if (!result.ok) {
        return new Response(
          JSON.stringify({ ok: false, type: result.type, error: "provider_verification_failed" }),
          { status: 401, headers: jsonHeaders },
        );
      }

      const normalized = to91(result.verifiedPhone || "");
      if (!normalized || last10(normalized).length !== 10) {
        console.error("[msg91-otp] verified phone missing");
        return jsonFailure("verified_phone_missing", 401);
      }

      if (body.phone) {
        const claimed = to91(body.phone);
        if (last10(claimed) !== last10(normalized)) {
          console.error("[msg91-otp] phone verification mismatch");
          return jsonFailure("phone_verification_mismatch", 409);
        }
      }

      // Claim the provider token and enforce phone/IP windows BEFORE any public
      // identity query/write, Auth mutation, pending-profile write, or token mint.
      const tokenClaim = await claimVerifiedToken(body.accessToken, normalized, attempt.ipDigest);
      if ("error" in tokenClaim) return jsonFailure(tokenClaim.error, tokenClaim.status);

      const e164 = `+${normalized}`;
      const publicMatches = await findPublicIdentityMatches(normalized);
      if ("error" in publicMatches) return jsonFailure(publicMatches.error, 500);
      if (publicMatches.ids.length > 1) {
        console.error("[msg91-otp] duplicate phone identity", JSON.stringify({ matches: publicMatches.ids.length }));
        return jsonFailure("duplicate_phone_identity", 409);
      }

      let authRef: AuthUserRef;
      let isNew = false;

      if (publicMatches.ids.length === 1) {
        const { data: authLookup, error } = await supabaseAdmin.auth.admin.getUserById(publicMatches.ids[0]);
        if (error || !authLookup?.user) {
          console.error("[msg91-otp] auth identity lookup failed", providerErrorCode(error));
          return jsonFailure("phone_already_linked_to_other_identity", 409);
        }
        const bound = await ensureInternalEmail(authLookup.user.id, authLookup.user.email || "", normalized);
        if ("error" in bound) return jsonFailure(bound.error, 500);
        authRef = { userId: authLookup.user.id, email: bound.email };
      } else {
        const created = await createAuthUserForPhone(e164, normalized);
        if ("error" in created) return jsonFailure(created.error, 500);
        authRef = created;
        isNew = true;
        const pending = await ensurePendingProfile(authRef.userId, e164);
        if ("error" in pending) return jsonFailure(pending.error, 500);
      }

      const mint = await mintMagicTokenHash(authRef.email);
      if ("error" in mint) return jsonFailure(mint.error, 502);

      console.log("[msg91-otp] verify_widget success", JSON.stringify({ is_new: isNew }));
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
      const phone = body.phone || "";
      if (!phone) return jsonFailure("phone required", 400);
      if (!MSG91_ENABLED) return jsonFailure("provider_configuration_unavailable", 503);
      const otp = genOtp();
      const text = `Your Oasis Baklawa login code is ${otp}. Valid for 5 minutes. Do not share this code.`;
      const result = await deliver(phone, body.email ?? null, text, "Oasis Baklawa Login Code", body.skip || []);
      return new Response(
        JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried }),
        { headers: jsonHeaders },
      );
    }

    if (body.mode === "order_received") {
      const phone = body.phone || "";
      const text = body.message || "Your order has been received by Oasis Baklawa. Our team will confirm shortly.";
      const result = await deliver(phone, body.email ?? null, text, "Order Received — Oasis Baklawa", body.skip || []);
      return new Response(
        JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried }),
        { headers: jsonHeaders },
      );
    }

    return jsonFailure("unknown mode", 400);
  } catch (error) {
    console.error("[msg91-otp] fatal", errorName(error));
    return jsonFailure("internal_error", 500);
  }
});
