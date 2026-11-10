// MSG91 OTP & Notification Service
// ----------------------------------
// Modes:
//   1. mode: "verify_widget"  → Server-side verifyAccessToken from MSG91 OTP Widget.
//   2. mode: "login_otp"      → (Legacy) send a 6-digit OTP via failover ladder.
//   3. mode: "order_received" → Notify a client that their WhatsApp order was logged.

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
  accessToken?: string;
  phone?: string;
  email?: string | null;
  message?: string;
  otp?: string;
  skip?: Channel[];
}

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

type PublicIdentityMatchResult = {
  ids: string[];
  unboundCompanyMemberIds: string[];
  approvedB2bPendingClaim: boolean;
};

async function phoneBoundUserIdsAmong(
  userIds: string[],
  variants: string[],
  pattern: string,
): Promise<Set<string> | { error: string }> {
  if (!userIds.length) return new Set();
  if (!supabaseAdmin) return { error: "service_role_unavailable" };

  const [phoneResult, mobileResult, secondaryResult, patternResult] = await Promise.all([
    supabaseAdmin.from("users").select("id").in("id", userIds).in("phone", variants),
    supabaseAdmin.from("users").select("id").in("id", userIds).in("mobile_number", variants),
    supabaseAdmin.from("users").select("id").in("id", userIds).overlaps("secondary_phones", variants),
    supabaseAdmin.from("users").select("id").in("id", userIds).or(`phone.ilike.${pattern},mobile_number.ilike.${pattern}`),
  ]);

  const lookupError = phoneResult.error || mobileResult.error || secondaryResult.error || patternResult.error;
  if (lookupError) {
    console.error("[msg91] b2b user phone binding lookup error:", maskSecret(lookupError.message ?? null) ?? "unknown");
    return { error: "identity_lookup_failed" };
  }

  const bound = new Set<string>();
  for (const row of [
    ...(phoneResult.data || []),
    ...(mobileResult.data || []),
    ...(secondaryResult.data || []),
    ...(patternResult.data || []),
  ]) {
    if (row?.id) bound.add(String(row.id));
  }
  return bound;
}

async function findPublicIdentityMatches(normalized: string): Promise<PublicIdentityMatchResult | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const variants = phoneVariants(normalized);
  const tail = last10(normalized);
  if (!variants.length || tail.length < 10) return { error: "phone_invalid" };
  const pattern = `%${tail}%`;

  const [phoneResult, mobileResult, secondaryResult, phonePatternResult, appResult, companyResult] = await Promise.all([
    supabaseAdmin.from("users").select("id").in("phone", variants),
    supabaseAdmin.from("users").select("id").in("mobile_number", variants),
    supabaseAdmin.from("users").select("id").overlaps("secondary_phones", variants),
    supabaseAdmin.from("users").select("id").or(`phone.ilike.${pattern},mobile_number.ilike.${pattern}`),
    supabaseAdmin.from("b2b_applications").select("user_id, resolved_company_id").eq("status", "approved").or(`contact_phone.ilike.${pattern},mobile_number.ilike.${pattern}`),
    supabaseAdmin.from("companies").select("id").ilike("phone", pattern),
  ]);

  const lookupError = phoneResult.error || mobileResult.error || secondaryResult.error || phonePatternResult.error || appResult.error || companyResult.error;
  if (lookupError) {
    console.error("[msg91] identity lookup error:", maskSecret(lookupError.message ?? null) ?? "unknown");
    return { error: "identity_lookup_failed" };
  }

  const ids = new Set<string>();
  for (const row of [
    ...(phoneResult.data || []),
    ...(mobileResult.data || []),
    ...(secondaryResult.data || []),
    ...(phonePatternResult.data || []),
  ]) {
    if (row?.id) ids.add(String(row.id));
  }

  const companyIds = new Set<string>();
  const b2bUserIds = new Set<string>();
  let approvedB2bPendingClaim = false;
  for (const app of appResult.data || []) {
    if (app?.user_id) b2bUserIds.add(String(app.user_id));
    else approvedB2bPendingClaim = true;
    if (app?.resolved_company_id) companyIds.add(String(app.resolved_company_id));
  }

  if (b2bUserIds.size > 0) {
    const phoneBoundB2b = await phoneBoundUserIdsAmong([...b2bUserIds], variants, pattern);
    if ("error" in phoneBoundB2b) return phoneBoundB2b;
    for (const userId of phoneBoundB2b) ids.add(userId);
    if (phoneBoundB2b.size < b2bUserIds.size) approvedB2bPendingClaim = true;
  }
  for (const company of companyResult.data || []) {
    if (company?.id) companyIds.add(String(company.id));
  }

  const unboundCompanyMemberIds = new Set<string>();
  if (companyIds.size > 0) {
    const { data: companyUsers, error: companyUserError } = await supabaseAdmin.from("users").select("id").in("company_id", [...companyIds]);
    if (companyUserError) {
      console.error("[msg91] company membership lookup error:", maskSecret(companyUserError.message ?? null) ?? "unknown");
      return { error: "identity_lookup_failed" };
    }
    for (const row of companyUsers || []) {
      if (row?.id) unboundCompanyMemberIds.add(String(row.id));
    }
  }

  return {
    ids: [...ids],
    unboundCompanyMemberIds: [...unboundCompanyMemberIds],
    approvedB2bPendingClaim,
  };
}

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

type PendingProfileResult = { ok: true } | { error: string };

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

const AUTH_KEY = (Deno.env.get("MSG91_AUTH_KEY") || "").trim();
const SENDER_ID = Deno.env.get("MSG91_SENDER_ID") || "OASBKL";
const VOICE_DID = Deno.env.get("MSG91_VOICE_DID") || "";
const MSG91_ENABLED = Boolean(AUTH_KEY);
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
      authKey: maskSecret(AUTH_KEY),
      accessToken: maskSecret(accessToken),
      raw,
    }));
    return { ok: res.ok && raw.type === "success", raw };
  } catch (e) {
    console.error("[msg91] verifyAccessToken failed:", e);
    return { ok: false, raw: { error: e instanceof Error ? e.message : "unknown" } };
  }
}

async function sendWhatsApp(phone: string, body: string): Promise<boolean> {
  if (!MSG91_ENABLED) return false;
  try {
    const res = await fetch("https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/", {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: AUTH_KEY },
      body: JSON.stringify({ integrated_number: SENDER_ID, content_type: "text", payload: { to: to91(phone), type: "text", text: { body } } }),
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
      body: JSON.stringify({ from: "Oasis Baklawa <noreply@oasisbaklawa.com>", to: [email], subject, text: body }),
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

async function deliver(phone: string, email: string | null | undefined, body: string, subject: string, skip: Channel[] = []) {
  const tried: Channel[] = [];
  if (!skip.includes("whatsapp") && phone) { tried.push("whatsapp"); if (await sendWhatsApp(phone, body)) return { delivered: true, channel: "whatsapp" as Channel, tried }; }
  if (!skip.includes("sms") && phone) { tried.push("sms"); if (await sendSMS(phone, body)) return { delivered: true, channel: "sms" as Channel, tried }; }
  if (!skip.includes("email") && email) { tried.push("email"); if (await sendEmail(email, subject, body)) return { delivered: true, channel: "email" as Channel, tried }; }
  if (!skip.includes("voice") && phone) { tried.push("voice"); if (await sendVoice(phone, body)) return { delivered: true, channel: "voice" as Channel, tried }; }
  return { delivered: false, channel: null, tried };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  try {
    const body = (await req.json()) as RequestBody;
    if (!body?.mode) return new Response(JSON.stringify({ ok: false, error: "mode is required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });

    if (body.mode === "verify_widget") {
      if (!body.accessToken) return new Response(JSON.stringify({ ok: false, error: "accessToken required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      const result = await verifyAccessToken(body.accessToken);
      if (!result.ok) return new Response(JSON.stringify({ ok: false, type: typeof result.raw.type === "string" ? result.raw.type : null, error: "provider_verification_failed" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });

      const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
      const fail = (error: string, status: number) => new Response(JSON.stringify({ ok: false, error }), { status, headers: jsonHeaders });
      const rawPhone = extractProviderVerifiedPhone(result.raw) || "";
      const normalized = to91(String(rawPhone));
      if (!normalized || normalized.length < 10) return fail("verified_phone_missing", 401);
      if (body.phone && last10(to91(String(body.phone))) !== last10(normalized)) return fail("phone_verification_mismatch", 409);
      const e164 = `+${normalized}`;

      const publicMatches = await findPublicIdentityMatches(normalized);
      if ("error" in publicMatches) return fail(publicMatches.error, 500);
      if (publicMatches.ids.length > 1) return fail("duplicate_phone_identity", 409);
      if (publicMatches.ids.length === 0 && publicMatches.unboundCompanyMemberIds.length > 0 && !publicMatches.approvedB2bPendingClaim) return fail("ambiguous_phone_identity", 409);

      let authRef: AuthUserRef;
      let isNew = false;
      const approvedB2bPendingClaim = publicMatches.approvedB2bPendingClaim;
      if (publicMatches.ids.length === 1) {
        const publicId = publicMatches.ids[0];
        const { data: authLookup, error: authLookupError } = await supabaseAdmin!.auth.admin.getUserById(publicId);
        if (authLookupError || !authLookup?.user) return fail("phone_already_linked_to_other_identity", 409);
        const bound = await ensureInternalEmail(authLookup.user.id, authLookup.user.email || "", normalized);
        if ("error" in bound) return fail(bound.error, 500);
        authRef = { userId: authLookup.user.id, email: bound.email };
      } else {
        const created = await createAuthUserForPhone(e164, normalized);
        if ("error" in created) return fail(created.error, 500);
        authRef = created;
        isNew = true;
        const pending = await ensurePendingProfile(authRef.userId, e164);
        if ("error" in pending) return fail(pending.error, 500);
      }

      const mint = await mintMagicTokenHash(authRef.email);
      if ("error" in mint) return fail(mint.error, 502);
      return new Response(JSON.stringify({ ok: true, type: "success", user_id: authRef.userId, email: authRef.email, phone: e164, is_new: isNew, approved_b2b_pending_claim: approvedB2bPendingClaim, token_hash: mint.tokenHash }), { status: 200, headers: jsonHeaders });
    }

    if (body.mode === "login_otp") {
      const otp = body.otp || genOtp();
      const phone = body.phone || "";
      if (!phone) return new Response(JSON.stringify({ ok: false, error: "phone required" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      const text = `Your Oasis Baklawa login code is ${otp}. Valid for 5 minutes. Do not share this code.`;
      const result = await deliver(phone, body.email ?? null, text, "Oasis Baklawa Login Code", body.skip || []);
      return new Response(JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried, otp }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (body.mode === "order_received") {
      const phone = body.phone || "";
      const text = body.message || "Your order has been received by Oasis Baklawa. Our team will confirm shortly.";
      const result = await deliver(phone, body.email ?? null, text, "Order Received — Oasis Baklawa", body.skip || []);
      return new Response(JSON.stringify({ ok: result.delivered, channel: result.channel, tried: result.tried }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ ok: false, error: "unknown mode" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[msg91-otp] fatal:", e);
    return new Response(JSON.stringify({ ok: false, error: e instanceof Error ? e.message : "unknown" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
