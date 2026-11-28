// Buyer Login Gateway
// -------------------
// Anonymous pre-auth boundary for Buyer eligibility only. It never sends OTPs,
// creates Auth users, mutates applications, or grants Buyer authority. Approved
// identities continue to the provider-specific verification path in BuyerLogin.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const admin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

type Channel = "mobile" | "email";
type EligibilityState = "approved" | "pending" | "employee" | "rejected" | "unknown" | "ambiguous";
type Eligibility = { state: EligibilityState; allowOtp: boolean; message: string };

const BUYER_ROLES = new Set([
  "B2B_BUYER", "SPECIAL_BUYER", "HORECA_BUYER", "WHOLESALE_BUYER",
  "BULK_BUYER", "BUYER", "CLIENT", "CUSTOMER_USER",
]);
const PENDING_ROLES = new Set(["PENDING", "PENDING_BUYER"]);

// Best-effort hot-worker limiter. Raw identifiers/IPs are never retained.
const WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 12;
const rateBuckets = new Map<string, { count: number; resetAt: number }>();

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function isRateLimited(req: Request, channel: Channel, identifier: string) {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  const key = (await sha256(`${forwarded}|${channel}|${identifier.trim().toLowerCase()}`)).slice(0, 32);
  const now = Date.now();
  const current = rateBuckets.get(key);
  if (!current || current.resetAt <= now) {
    rateBuckets.set(key, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  current.count += 1;
  return current.count > MAX_REQUESTS_PER_WINDOW;
}

function normalizeEmail(raw: string) {
  return raw.trim().toLowerCase();
}

function normalizePhone(raw: string) {
  const digits = raw.replace(/\D/g, "");
  const tail = digits.length >= 10 ? digits.slice(-10) : digits;
  return tail.length === 10 ? `91${tail}` : "";
}

function phoneVariants(normalized: string) {
  const tail = normalized.slice(-10);
  return [...new Set([tail, `91${tail}`, `+91${tail}`, `0${tail}`])];
}

function normalizeRole(role: unknown) {
  return typeof role === "string" ? role.trim().toUpperCase() : "";
}

function isEmployeeRole(role: unknown) {
  const normalized = normalizeRole(role);
  return Boolean(normalized) && !BUYER_ROLES.has(normalized) && !PENDING_ROLES.has(normalized);
}

function result(state: EligibilityState, channel: Channel): Eligibility {
  if (state === "approved") {
    return {
      state,
      allowOtp: true,
      message: channel === "mobile"
        ? "Approved B2B account found. Continue with mobile OTP."
        : "Approved B2B account found. Continue with email OTP.",
    };
  }
  if (state === "pending") {
    return { state, allowOtp: false, message: "Your B2B access request is under review. You will be able to log in after approval." };
  }
  if (state === "employee") {
    return {
      state,
      allowOtp: false,
      message: channel === "mobile"
        ? "This mobile number belongs to an Oasis employee account. Employees must use Admin Login."
        : "This email belongs to an Oasis employee account. Employees must use Admin Login.",
    };
  }
  if (state === "rejected") {
    return { state, allowOtp: false, message: "This B2B access request is not active. Please contact Oasis support or submit a new access request if eligible." };
  }
  if (state === "ambiguous") {
    return { state, allowOtp: false, message: "We found conflicting account records for this login. Please contact Oasis support before continuing." };
  }
  return {
    state: "unknown",
    allowOtp: false,
    message: channel === "mobile"
      ? "This mobile number is not registered for B2B access."
      : "This email is not registered for B2B access.",
  };
}

async function classifyEmail(identifier: string): Promise<Eligibility> {
  if (!admin) return result("ambiguous", "email");
  const email = normalizeEmail(identifier);
  if (!email || !email.includes("@")) return result("unknown", "email");

  const [usersRes, profilesRes, appsRes] = await Promise.all([
    admin.from("users").select("id,role,is_active,company_id,email").ilike("email", email).limit(10),
    admin.from("profiles").select("id,role,status,is_approved,company_id,email").ilike("email", email).limit(10),
    admin.from("b2b_applications")
      .select("id,status,user_id,resolved_company_id,created_at")
      .ilike("contact_email", email)
      .order("created_at", { ascending: false })
      .limit(20),
  ]);
  const lookupError = usersRes.error || profilesRes.error || appsRes.error;
  if (lookupError) {
    console.error("[buyer-login-gateway] email lookup failed", lookupError.message);
    return result("ambiguous", "email");
  }

  const staff = [
    ...(usersRes.data || []).filter((row) => row?.is_active !== false),
    ...(profilesRes.data || []).filter((row) => row?.status !== "disabled"),
  ].some((row) => isEmployeeRole(row?.role));
  if (staff) return result("employee", "email");

  const activeBuyer = (usersRes.data || []).some((row) =>
    row?.is_active !== false && BUYER_ROLES.has(normalizeRole(row?.role)) && Boolean(row?.company_id)
  ) || (profilesRes.data || []).some((row) =>
    row?.is_approved === true && BUYER_ROLES.has(normalizeRole(row?.role)) && Boolean(row?.company_id)
  );

  const apps = appsRes.data || [];
  const approved = apps.filter((row) => String(row?.status || "").toLowerCase() === "approved" && row?.resolved_company_id);
  const approvedCompanies = new Set(approved.map((row) => String(row.resolved_company_id)));
  if (approvedCompanies.size > 1) return result("ambiguous", "email");
  if (activeBuyer || approved.length > 0) return result("approved", "email");
  if (apps.some((row) => String(row?.status || "").toLowerCase() === "pending")) return result("pending", "email");
  if (apps.some((row) => String(row?.status || "").toLowerCase() === "rejected")) return result("rejected", "email");
  return result("unknown", "email");
}

async function classifyMobile(identifier: string): Promise<Eligibility> {
  if (!admin) return result("ambiguous", "mobile");
  const normalized = normalizePhone(identifier);
  if (!normalized) return result("unknown", "mobile");
  const variants = phoneVariants(normalized);
  const pattern = `%${normalized.slice(-10)}%`;

  const [phoneUsers, mobileUsers, secondaryUsers, profilesRes, appsRes] = await Promise.all([
    admin.from("users").select("id,role,is_active,company_id,phone,mobile_number").in("phone", variants),
    admin.from("users").select("id,role,is_active,company_id,phone,mobile_number").in("mobile_number", variants),
    admin.from("users").select("id,role,is_active,company_id,phone,mobile_number").overlaps("secondary_phones", variants),
    admin.from("profiles").select("id,role,status,is_approved,company_id,mobile_number").ilike("mobile_number", pattern).limit(20),
    admin.from("b2b_applications")
      .select("id,status,user_id,resolved_company_id,created_at")
      .or(`contact_phone.ilike.${pattern},mobile_number.ilike.${pattern}`)
      .order("created_at", { ascending: false })
      .limit(20),
  ]);
  const lookupError = phoneUsers.error || mobileUsers.error || secondaryUsers.error || profilesRes.error || appsRes.error;
  if (lookupError) {
    console.error("[buyer-login-gateway] mobile lookup failed", lookupError.message);
    return result("ambiguous", "mobile");
  }

  const userMap = new Map<string, Record<string, unknown>>();
  for (const row of [...(phoneUsers.data || []), ...(mobileUsers.data || []), ...(secondaryUsers.data || [])]) {
    if (row?.id) userMap.set(String(row.id), row as Record<string, unknown>);
  }
  const staff = [
    ...userMap.values(),
    ...(profilesRes.data || []).filter((row) => row?.status !== "disabled"),
  ].some((row) => isEmployeeRole(row?.role));
  if (staff) return result("employee", "mobile");

  const activeBuyer = [...userMap.values()].some((row) =>
    row?.is_active !== false && BUYER_ROLES.has(normalizeRole(row?.role)) && Boolean(row?.company_id)
  ) || (profilesRes.data || []).some((row) =>
    row?.is_approved === true && BUYER_ROLES.has(normalizeRole(row?.role)) && Boolean(row?.company_id)
  );

  const apps = appsRes.data || [];
  const approved = apps.filter((row) => String(row?.status || "").toLowerCase() === "approved" && row?.resolved_company_id);
  const approvedCompanies = new Set(approved.map((row) => String(row.resolved_company_id)));
  if (approvedCompanies.size > 1) return result("ambiguous", "mobile");
  if (activeBuyer || approved.length > 0) return result("approved", "mobile");
  if (apps.some((row) => String(row?.status || "").toLowerCase() === "pending")) return result("pending", "mobile");
  if (apps.some((row) => String(row?.status || "").toLowerCase() === "rejected")) return result("rejected", "mobile");
  return result("unknown", "mobile");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const body = await req.json() as { mode?: string; channel?: Channel; identifier?: string; attemptId?: string };
    const channel = body.channel;
    const identifier = typeof body.identifier === "string" ? body.identifier : "";
    if (body.mode !== "preflight" || !channel || !identifier.trim()) return json({ ok: false, error: "invalid_request" }, 400);
    if (await isRateLimited(req, channel, identifier)) return json({ ok: false, error: "rate_limited" }, 429);

    const eligibility = channel === "email"
      ? await classifyEmail(identifier)
      : await classifyMobile(identifier);
    return json({ ok: true, ...eligibility });
  } catch (error) {
    console.error("[buyer-login-gateway] fatal", error instanceof Error ? error.name : "unknown");
    return json({ ok: false, error: "gateway_failure" }, 500);
  }
});
