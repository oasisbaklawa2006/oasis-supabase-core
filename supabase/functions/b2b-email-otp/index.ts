import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Pragma": "no-cache",
      "X-Content-Type-Options": "nosniff",
    },
  });

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") || "";
const admin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

const CHALLENGE_TTL_MS = 10 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;
const MAX_SENDS_PER_HOUR = 5;

type SendBody = { mode: "send"; email?: unknown };
type VerifyBody = { mode: "verify"; challengeId?: unknown; otp?: unknown };
type Body = SendBody | VerifyBody | { mode?: unknown };

type ApplicationRow = {
  id: string;
  status: string | null;
  user_id: string | null;
  resolved_company_id: string | null;
  contact_email: string | null;
  mobile_number: string | null;
  contact_phone: string | null;
  contact_person: string | null;
  contact_name: string | null;
};

type ConsumeRow = {
  verified?: boolean;
  application_id?: string | null;
  normalized_email?: string | null;
  failure_reason?: string | null;
};

type PlaceholderRow = {
  placeholder_user_id?: string | null;
  application_id?: string | null;
  eligible?: boolean;
  reason?: string | null;
};

function firstRow<T>(data: unknown): T | null {
  if (Array.isArray(data)) return (data[0] as T | undefined) ?? null;
  return data && typeof data === "object" ? data as T : null;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function normalizeIndianPhone(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const digits = value.replace(/\D/g, "");
  if (digits.length === 10) return `+91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return `+${digits}`;
  return null;
}

function internalPhoneAliasEmail(phone: string): string {
  return `${phone.replace(/\D/g, "")}@phone.oasis.local`;
}

function secureSixDigitOtp(): string {
  // Rejection sampling avoids modulo bias while keeping the code exactly six digits.
  const limit = Math.floor(0x1_0000_0000 / 900_000) * 900_000;
  const values = new Uint32Array(1);
  let value = 0;
  do {
    crypto.getRandomValues(values);
    value = values[0];
  } while (value >= limit);
  return String(100_000 + (value % 900_000));
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function otpMac(challengeId: string, email: string, otp: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SERVICE_ROLE_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${challengeId}|${email}|${otp}`),
  ));
}

async function sendOtpEmail(email: string, otp: string): Promise<boolean> {
  if (!RESEND_API_KEY) return false;
  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      signal: AbortSignal.timeout(10_000),
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${RESEND_API_KEY}`,
      },
      body: JSON.stringify({
        from: "Oasis Baklawa <team@oasisbaklawa.com>",
        to: [email],
        subject: "Your Oasis Baklawa login code",
        html: `<div style="font-family:Arial,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1a1a1a">
          <h2 style="margin:0 0 16px">Oasis Baklawa B2B</h2>
          <p>Your secure login code is:</p>
          <div style="font-size:30px;font-weight:700;letter-spacing:8px;margin:20px 0">${otp}</div>
          <p>This code expires in 10 minutes and can be used once.</p>
          <p style="font-size:12px;color:#777">If you did not request this code, you can ignore this email.</p>
        </div>`,
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function loadApprovedApplicationByEmail(email: string): Promise<ApplicationRow | null> {
  if (!admin) return null;
  const { data, error } = await admin
    .from("b2b_applications")
    .select("id,status,user_id,resolved_company_id,contact_email,mobile_number,contact_phone,contact_person,contact_name")
    .eq("status", "approved")
    .eq("contact_email", email)
    .order("reviewed_at", { ascending: false, nullsFirst: false })
    .limit(2);
  if (error || !Array.isArray(data) || data.length !== 1) return null;
  return data[0] as ApplicationRow;
}

async function loadApplicationById(applicationId: string): Promise<ApplicationRow | null> {
  if (!admin) return null;
  const { data, error } = await admin
    .from("b2b_applications")
    .select("id,status,user_id,resolved_company_id,contact_email,mobile_number,contact_phone,contact_person,contact_name")
    .eq("id", applicationId)
    .maybeSingle();
  if (error || !data) return null;
  return data as ApplicationRow;
}

async function findSafeLegacyPlaceholder(phone: string, applicationId: string): Promise<string | null> {
  if (!admin) return null;
  const { data, error } = await admin.rpc("inspect_b2b_pending_phone_placeholder_v1", {
    p_verified_phone: phone,
  });
  if (error) return null;
  const row = firstRow<PlaceholderRow>(data);
  if (row?.eligible === true && row.application_id === applicationId && row.placeholder_user_id) {
    return row.placeholder_user_id;
  }
  if (row?.reason && row.reason !== "placeholder_not_found") {
    throw new Error("identity_collision");
  }
  return null;
}

async function createCanonicalAuthIdentity(app: ApplicationRow, verifiedEmail: string) {
  if (!admin) throw new Error("auth_service_unavailable");
  const phone = normalizeIndianPhone(app.mobile_number || app.contact_phone);
  if (!phone) throw new Error("approved_phone_invalid");
  const placeholderId = await findSafeLegacyPlaceholder(phone, app.id);
  const aliasEmail = internalPhoneAliasEmail(phone);
  const { data, error } = await admin.auth.admin.createUser({
    ...(placeholderId ? { id: placeholderId } : {}),
    phone,
    phone_confirm: false,
    email: aliasEmail,
    email_confirm: true,
    user_metadata: {
      b2b_application_id: app.id,
      verified_login_email: verifiedEmail,
      provisioned_via: "b2b-email-otp",
    },
  });
  if (error || !data.user?.id) throw new Error("canonical_identity_create_failed");
  return { userId: data.user.id, authEmail: data.user.email || aliasEmail, created: true };
}

async function resolveCanonicalIdentity(app: ApplicationRow, verifiedEmail: string) {
  if (!admin) throw new Error("auth_service_unavailable");
  if (app.user_id) {
    const { data, error } = await admin.auth.admin.getUserById(app.user_id);
    if (error || !data.user?.id || !data.user.email) throw new Error("canonical_identity_missing");
    const { data: staff, error: staffError } = await admin.rpc("is_internal_staff", { _user_id: data.user.id });
    if (staffError || staff === true) throw new Error("canonical_identity_forbidden");
    return { userId: data.user.id, authEmail: data.user.email, created: false };
  }
  return await createCanonicalAuthIdentity(app, verifiedEmail);
}

async function activateIfNeeded(app: ApplicationRow, userId: string, verifiedEmail: string) {
  if (!admin || app.user_id) return;
  const { data, error } = await admin.rpc("activate_approved_b2b_access_by_verified_email_v1", {
    p_application_id: app.id,
    p_auth_user_id: userId,
    p_verified_email: verifiedEmail,
  });
  if (error) throw new Error("buyer_activation_failed");
  const row = firstRow<{ activated?: boolean; already_active?: boolean }>(data);
  if (!row || (row.activated !== true && row.already_active !== true)) {
    throw new Error("buyer_activation_failed");
  }
}

async function mintSessionTokenHash(email: string): Promise<string> {
  if (!admin) throw new Error("auth_service_unavailable");
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (error || !data) throw new Error("session_token_mint_failed");
  const properties = data.properties || {};
  if (typeof properties.hashed_token === "string" && properties.hashed_token) {
    return properties.hashed_token;
  }
  const actionLink = typeof properties.action_link === "string" ? properties.action_link : "";
  const match = actionLink.match(/token_hash=([^&]+)/) || actionLink.match(/[?#&]token=([^&]+)/);
  if (!match) throw new Error("session_token_mint_failed");
  return decodeURIComponent(match[1]);
}

async function handleSend(email: string): Promise<Response> {
  if (!admin || !SERVICE_ROLE_KEY) return json({ ok: false, error: "auth_service_unavailable" }, 503);
  if (!RESEND_API_KEY) return json({ ok: false, error: "email_delivery_unavailable" }, 503);

  const app = await loadApprovedApplicationByEmail(email);
  if (!app) {
    // Do not disclose whether an email is registered/approved.
    await new Promise((resolve) => setTimeout(resolve, 150));
    return json({ ok: true, challenge_id: crypto.randomUUID(), sent: true });
  }

  const oneMinuteAgo = new Date(Date.now() - RESEND_COOLDOWN_MS).toISOString();
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const [{ count: recent }, { count: hourly }] = await Promise.all([
    admin.from("b2b_email_otp_challenges").select("id", { count: "exact", head: true })
      .eq("normalized_email", email).gte("created_at", oneMinuteAgo),
    admin.from("b2b_email_otp_challenges").select("id", { count: "exact", head: true })
      .eq("normalized_email", email).gte("created_at", oneHourAgo),
  ]);
  if ((recent ?? 0) > 0 || (hourly ?? 0) >= MAX_SENDS_PER_HOUR) {
    return json({ ok: false, error: "otp_rate_limited" }, 429);
  }

  const challengeId = crypto.randomUUID();
  const otp = secureSixDigitOtp();
  const mac = await otpMac(challengeId, email, otp);
  const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS).toISOString();
  const { error: insertError } = await admin.from("b2b_email_otp_challenges").insert({
    id: challengeId,
    application_id: app.id,
    normalized_email: email,
    otp_mac: mac,
    expires_at: expiresAt,
    max_attempts: 5,
  });
  if (insertError) return json({ ok: false, error: "otp_challenge_create_failed" }, 500);

  if (!(await sendOtpEmail(email, otp))) {
    await admin.from("b2b_email_otp_challenges").update({ consumed_at: new Date().toISOString() }).eq("id", challengeId);
    return json({ ok: false, error: "email_delivery_failed" }, 502);
  }

  return json({ ok: true, challenge_id: challengeId, sent: true, expires_in_seconds: 600 });
}

async function handleVerify(challengeId: string, otp: string): Promise<Response> {
  if (!admin || !SERVICE_ROLE_KEY) return json({ ok: false, error: "auth_service_unavailable" }, 503);
  const { data: challenge, error: challengeError } = await admin
    .from("b2b_email_otp_challenges")
    .select("normalized_email")
    .eq("id", challengeId)
    .maybeSingle();
  if (challengeError || !challenge?.normalized_email) {
    return json({ ok: false, error: "otp_invalid_or_expired" }, 400);
  }

  const mac = await otpMac(challengeId, challenge.normalized_email, otp);
  const { data, error } = await admin.rpc("consume_b2b_email_otp_challenge_v1", {
    p_challenge_id: challengeId,
    p_otp_mac: mac,
  });
  if (error) return json({ ok: false, error: "otp_verification_failed" }, 500);
  const consumed = firstRow<ConsumeRow>(data);
  if (!consumed?.verified || !consumed.application_id || !consumed.normalized_email) {
    return json({ ok: false, error: "otp_invalid_or_expired" }, 400);
  }

  const app = await loadApplicationById(consumed.application_id);
  if (
    !app || app.status !== "approved" || !app.resolved_company_id ||
    normalizeEmail(app.contact_email) !== consumed.normalized_email
  ) {
    return json({ ok: false, error: "approved_application_unavailable" }, 409);
  }

  let identity: { userId: string; authEmail: string; created: boolean } | null = null;
  try {
    identity = await resolveCanonicalIdentity(app, consumed.normalized_email);
    await activateIfNeeded(app, identity.userId, consumed.normalized_email);
    const tokenHash = await mintSessionTokenHash(identity.authEmail);
    return json({
      ok: true,
      type: "success",
      user_id: identity.userId,
      token_hash: tokenHash,
    });
  } catch (error) {
    if (identity?.created) {
      // If activation committed but response/minting later failed, preserve the
      // canonical identity. Otherwise remove the orphan Auth row so a retry can converge.
      const refreshed = await loadApplicationById(app.id);
      if (refreshed?.user_id !== identity.userId) {
        await admin.auth.admin.deleteUser(identity.userId).catch(() => undefined);
      }
    }
    const code = error instanceof Error ? error.message : "email_otp_login_failed";
    const status = code.includes("collision") || code.includes("forbidden") ? 409 : 500;
    return json({ ok: false, error: code }, status);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  try {
    const body = await req.json() as Body;
    if (body.mode === "send") {
      const email = normalizeEmail((body as SendBody).email);
      if (!email) return json({ ok: false, error: "email_invalid" }, 400);
      return await handleSend(email);
    }
    if (body.mode === "verify") {
      const challengeId = typeof (body as VerifyBody).challengeId === "string"
        ? (body as VerifyBody).challengeId!.trim()
        : "";
      const otp = typeof (body as VerifyBody).otp === "string"
        ? (body as VerifyBody).otp!.replace(/\D/g, "")
        : "";
      if (!/^[0-9a-f-]{36}$/i.test(challengeId) || !/^\d{6}$/.test(otp)) {
        return json({ ok: false, error: "otp_invalid_or_expired" }, 400);
      }
      return await handleVerify(challengeId, otp);
    }
    return json({ ok: false, error: "unsupported_mode" }, 400);
  } catch {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
});
