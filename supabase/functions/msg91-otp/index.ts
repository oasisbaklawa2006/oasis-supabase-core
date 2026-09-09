// MSG91 OTP verification and notification service.
// Authentication authority is fail-closed:
// 1) MSG91 verifies the customer-entered OTP.
// 2) This function re-verifies MSG91's access token server-side.
// 3) Only the phone returned by MSG91 may establish identity.
// 4) Existing Oasis identities are reused; collisions are rejected.
// 5) A Supabase magic-link token hash is minted for the canonical auth user.
//
// No raw OTP, access token, provider payload, or server auth key is persisted.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

type Channel = "whatsapp" | "sms" | "email" | "voice";
type UnknownRecord = Record<string, unknown>;

type RequestBody = {
  mode: "verify_widget" | "login_otp" | "order_received";
  accessToken?: string;
  phone?: string;
  email?: string | null;
  message?: string;
  skip?: Channel[];
  attemptId?: string;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const AUTH_KEY = Deno.env.get("MSG91_AUTH_KEY") || "";
const SENDER_ID = Deno.env.get("MSG91_SENDER_ID") || "OASBKL";
const VOICE_DID = Deno.env.get("MSG91_VOICE_DID") || "";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") || "";

const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function digits(raw: string): string {
  return (raw || "").replace(/\D/g, "");
}

function last10(raw: string): string {
  const value = digits(raw);
  return value.length >= 10 ? value.slice(-10) : value;
}

function to91(raw: string): string {
  const value = digits(raw);
  if (value.length === 10) return `91${value}`;
  if (value.length === 12 && value.startsWith("91")) return value;
  if (value.length >= 10) return value.slice(-12);
  return value;
}

function phoneVariants(normalized: string): string[] {
  const tail = last10(normalized);
  if (tail.length !== 10) return [];
  return [...new Set([tail, `91${tail}`, `+91${tail}`, `0${tail}`])];
}

function internalEmailFor(normalized: string): string {
  return `${normalized}@phone.oasis.local`;
}

function asRecord(value: unknown): UnknownRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as UnknownRecord;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function providerVerifiedPhone(raw: UnknownRecord): string | null {
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

async function auditAuthEvent(input: {
  event: string;
  status: string;
  attemptId?: string | null;
  phone?: string | null;
  failureReason?: string | null;
  description?: string | null;
  payload?: Record<string, unknown>;
}) {
  if (!supabaseAdmin) return;
  try {
    await supabaseAdmin.from("auth_logs").insert({
      event_type: input.event,
      event_name: input.event,
      phone: input.phone ?? null,
      channel: "msg91_widget",
      status: input.status,
      request_id: input.attemptId ?? null,
      failure_reason: input.failureReason ?? null,
      description: input.description ?? null,
      raw_payload: input.payload ?? {},
    });
  } catch (error) {
    console.warn("[msg91-otp] auth audit soft-failed", error instanceof Error ? error.name : "unknown");
  }
}

async function verifyAccessToken(accessToken: string): Promise<{
  ok: boolean;
  status: number;
  type: string | null;
  raw: UnknownRecord;
}> {
  if (!AUTH_KEY) return { ok: false, status: 503, type: null, raw: {} };

  try {
    const res = await fetch("https://control.msg91.com/api/v5/widget/verifyAccessToken", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ authkey: AUTH_KEY, "access-token": accessToken }),
    });
    const raw = (await res.json().catch(() => ({}))) as UnknownRecord;
    const type = typeof raw.type === "string" ? raw.type : null;

    console.log("[msg91-otp] provider verification", JSON.stringify({
      http_ok: res.ok,
      status: res.status,
      type,
    }));

    return { ok: res.ok && type === "success", status: res.status, type, raw };
  } catch (error) {
    console.error("[msg91-otp] provider verification failed", error instanceof Error ? error.name : "unknown");
    return { ok: false, status: 502, type: null, raw: {} };
  }
}

async function findPublicIdentityMatches(normalized: string): Promise<string[]> {
  if (!supabaseAdmin) throw new Error("service_role_unavailable");
  const variants = phoneVariants(normalized);
  if (!variants.length) throw new Error("phone_invalid");

  const [phoneResult, mobileResult, secondaryResult] = await Promise.all([
    supabaseAdmin.from("users").select("id").in("phone", variants),
    supabaseAdmin.from("users").select("id").in("mobile_number", variants),
    supabaseAdmin.from("users").select("id").overlaps("secondary_phones", variants),
  ]);

  const error = phoneResult.error || mobileResult.error || secondaryResult.error;
  if (error) throw new Error("identity_lookup_failed");

  const ids = new Set<string>();
  for (const row of [...(phoneResult.data || []), ...(mobileResult.data || []), ...(secondaryResult.data || [])]) {
    if (row?.id) ids.add(String(row.id));
  }
  return [...ids];
}

async function ensureEmail(userId: string, currentEmail: string | null, normalized: string): Promise<string> {
  if (currentEmail) return currentEmail;
  if (!supabaseAdmin) throw new Error("service_role_unavailable");
  const email = internalEmailFor(normalized);
  const { error } = await supabaseAdmin.auth.admin.updateUserById(userId, {
    email,
    email_confirm: true,
  });
  if (error) throw new Error("auth_email_bind_failed");
  return email;
}

async function resolveCanonicalAuthUser(e164: string, normalized: string): Promise<{
  userId: string;
  email: string;
  isNew: boolean;
}> {
  if (!supabaseAdmin) throw new Error("service_role_unavailable");

  const publicMatches = await findPublicIdentityMatches(normalized);
  if (publicMatches.length > 1) throw new Error("duplicate_phone_identity");

  if (publicMatches.length === 1) {
    const userId = publicMatches[0];
    const { data, error } = await supabaseAdmin.auth.admin.getUserById(userId);
    if (error || !data?.user) throw new Error("phone_linked_to_missing_auth_identity");
    const email = await ensureEmail(data.user.id, data.user.email || null, normalized);
    return { userId: data.user.id, email, isNew: false };
  }

  const email = internalEmailFor(normalized);
  const { data, error } = await supabaseAdmin.auth.admin.createUser({
    phone: e164,
    phone_confirm: true,
    email,
    email_confirm: true,
  });
  if (error || !data?.user) throw new Error("auth_user_create_failed");

  const { error: pendingError } = await supabaseAdmin.from("users").insert({
    id: data.user.id,
    role: "PENDING",
    phone: e164,
    is_active: true,
  });

  if (pendingError) throw new Error("pending_profile_create_failed");
  return { userId: data.user.id, email, isNew: true };
}

async function mintMagicTokenHash(email: string): Promise<string> {
  if (!supabaseAdmin) throw new Error("service_role_unavailable");
  const { data, error } = await supabaseAdmin.auth.admin.generateLink({ type: "magiclink", email });
  if (error || !data) throw new Error("session_token_mint_failed");

  const props = data.properties || {};
  if (typeof props.hashed_token === "string" && props.hashed_token) return props.hashed_token;
  const link = typeof props.action_link === "string" ? props.action_link : "";
  const match = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
  if (!match) throw new Error("session_token_mint_failed");
  return decodeURIComponent(match[1]);
}

async function sendWhatsApp(phone: string, body: string): Promise<boolean> {
  if (!AUTH_KEY) return false;
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
  } catch {
    return false;
  }
}

async function sendSMS(phone: string, body: string): Promise<boolean> {
  if (!AUTH_KEY) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/flow/", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({ sender: SENDER_ID, short_url: "0", mobiles: to91(phone), body }),
    });
    return res.ok;
  } catch {
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
  } catch {
    return false;
  }
}

async function sendVoice(phone: string, body: string): Promise<boolean> {
  if (!AUTH_KEY || !VOICE_DID) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/voice/outbound", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({ from: VOICE_DID, to: to91(phone), text: body, voice: "female-en-IN" }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function deliver(phone: string, email: string | null | undefined, body: string, subject: string, skip: Channel[] = []) {
  const tried: Channel[] = [];
  if (!skip.includes("whatsapp") && phone) {
    tried.push("whatsapp");
    if (await sendWhatsApp(phone, body)) return { delivered: true, channel: "whatsapp" as const, tried };
  }
  if (!skip.includes("sms") && phone) {
    tried.push("sms");
    if (await sendSMS(phone, body)) return { delivered: true, channel: "sms" as const, tried };
  }
  if (!skip.includes("email") && email) {
    tried.push("email");
    if (await sendEmail(email, subject, body)) return { delivered: true, channel: "email" as const, tried };
  }
  if (!skip.includes("voice") && phone) {
    tried.push("voice");
    if (await sendVoice(phone, body)) return { delivered: true, channel: "voice" as const, tried };
  }
  return { delivered: false, channel: null, tried };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return response({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const body = (await req.json()) as RequestBody;
    if (!body?.mode) return response({ ok: false, error: "mode_required" }, 400);

    if (body.mode === "login_otp") {
      return response({ ok: false, error: "legacy_login_otp_disabled" }, 410);
    }

    if (body.mode === "verify_widget") {
      const attemptId = body.attemptId || crypto.randomUUID();

      if (!supabaseAdmin) {
        await auditAuthEvent({ event: "OTP_VERIFY_FAILED", status: "failed", attemptId, failureReason: "service_role_unavailable" });
        return response({ ok: false, error: "service_role_unavailable" }, 503);
      }
      if (!AUTH_KEY) {
        await auditAuthEvent({ event: "OTP_VERIFY_FAILED", status: "failed", attemptId, failureReason: "msg91_auth_key_missing" });
        return response({ ok: false, error: "msg91_not_configured" }, 503);
      }
      if (!body.accessToken) {
        await auditAuthEvent({ event: "OTP_VERIFY_FAILED", status: "failed", attemptId, failureReason: "access_token_missing" });
        return response({ ok: false, error: "accessToken_required" }, 400);
      }

      await auditAuthEvent({ event: "OTP_VERIFY_STARTED", status: "started", attemptId });
      const provider = await verifyAccessToken(body.accessToken);
      if (!provider.ok) {
        await auditAuthEvent({
          event: "OTP_VERIFY_FAILED",
          status: "failed",
          attemptId,
          failureReason: "provider_verification_failed",
          payload: { provider_http_status: provider.status, provider_type: provider.type },
        });
        return response({ ok: false, error: "provider_verification_failed" }, 401);
      }

      const rawProviderPhone = providerVerifiedPhone(provider.raw);
      const normalized = rawProviderPhone ? to91(rawProviderPhone) : "";
      if (normalized.length !== 12 || !normalized.startsWith("91")) {
        await auditAuthEvent({ event: "OTP_VERIFY_FAILED", status: "failed", attemptId, failureReason: "verified_phone_missing" });
        return response({ ok: false, error: "verified_phone_missing" }, 401);
      }

      const e164 = `+${normalized}`;
      if (body.phone && last10(body.phone) !== last10(normalized)) {
        await auditAuthEvent({
          event: "OTP_VERIFY_FAILED",
          status: "failed",
          attemptId,
          phone: e164,
          failureReason: "phone_verification_mismatch",
        });
        return response({ ok: false, error: "phone_verification_mismatch" }, 409);
      }

      try {
        const canonical = await resolveCanonicalAuthUser(e164, normalized);
        const tokenHash = await mintMagicTokenHash(canonical.email);

        await auditAuthEvent({
          event: "OTP_VERIFY_SUCCESS",
          status: "success",
          attemptId,
          phone: e164,
          payload: { user_id: canonical.userId, is_new: canonical.isNew },
        });
        await auditAuthEvent({
          event: "SESSION_TOKEN_MINTED",
          status: "success",
          attemptId,
          phone: e164,
          payload: { user_id: canonical.userId },
        });

        return response({
          ok: true,
          type: "success",
          user_id: canonical.userId,
          email: canonical.email,
          phone: e164,
          is_new: canonical.isNew,
          token_hash: tokenHash,
        });
      } catch (error) {
        const code = error instanceof Error ? error.message : "identity_resolution_failed";
        const conflict = ["duplicate_phone_identity", "phone_linked_to_missing_auth_identity", "auth_user_create_failed"].includes(code);

        await auditAuthEvent({
          event: "OTP_VERIFY_FAILED",
          status: "failed",
          attemptId,
          phone: e164,
          failureReason: code,
        });

        return response({ ok: false, error: code }, conflict ? 409 : 500);
      }
    }

    if (body.mode === "order_received") {
      const phone = body.phone || "";
      if (!phone) return response({ ok: false, error: "phone_required" }, 400);
      const text = body.message || "Your order has been received by Oasis Baklawa. Our team will confirm shortly.";
      const result = await deliver(phone, body.email ?? null, text, "Order Received — Oasis Baklawa", body.skip || []);
      return response({ ok: result.delivered, channel: result.channel, tried: result.tried });
    }

    return response({ ok: false, error: "unknown_mode" }, 400);
  } catch (error) {
    console.error("[msg91-otp] fatal", error instanceof Error ? error.name : "unknown");
    return response({ ok: false, error: "internal_error" }, 500);
  }
});
