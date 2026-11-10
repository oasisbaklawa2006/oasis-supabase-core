// MSG91 verified-widget authentication endpoint
// Legacy outbound modes (login_otp, order_received) are disabled before provider calls.

import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { rejectLegacyOutboundMode } from "./legacy-outbound-policy.mjs";
import { canonicalIndianPhone, phoneEquals, anyPhoneEquals } from "./strict-phone-match.mjs";

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

// Retry a previous Auth-create/profile-upsert split without deleting any Auth identity.
// Never infer ownership from phone alone: require both the deterministic internal email
// and an exactly matching, provider-verified phone, and reject ambiguous results.
async function findRecoverableAuthForPhone(normalized: string): Promise<AuthUserRef | null | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const email = internalEmailFor(normalized);
  const matches: AuthUserRef[] = [];
  const PAGE_SIZE = 1000;
  const MAX_PAGES = 20;
  try {
    for (let page = 1; page <= MAX_PAGES; page++) {
      const { data, error } = await supabaseAdmin.auth.admin.listUsers({ page, perPage: PAGE_SIZE });
      if (error || !data || !Array.isArray(data.users)) return { error: "auth_recovery_lookup_failed" };
      for (const user of data.users) {
        if (typeof user.email !== "string" || user.email.toLowerCase() !== email.toLowerCase()) continue;
        if (!phoneEquals(user.phone, normalized)) return { error: "auth_recovery_identity_conflict" };
        matches.push({ userId: user.id, email: user.email });
        if (matches.length > 1) return { error: "auth_recovery_identity_conflict" };
      }
      if (data.users.length < PAGE_SIZE) return matches[0] ?? null;
    }
    // A truncated enumeration cannot prove absence or uniqueness; fail closed.
    return { error: "auth_recovery_scan_incomplete" };
  } catch {
    return { error: "auth_recovery_lookup_failed" };
  }
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
  if (!createErr && created?.user) return { userId: created.user.id, email: internalEmail };
  // A duplicate or uncertain create outcome is not a reason to delete Auth state.
  // Reconcile only an exact deterministic email+phone match, never a phone-only claim.
  const existing = await findRecoverableAuthForPhone(normalized);
  if (existing && !("error" in existing)) return existing;
  console.error("[msg91] auth_user_create_failed:", createErr?.code ?? "unknown");
  return existing && "error" in existing ? existing : { error: "auth_user_create_failed" };
}

type PublicIdentityMatchResult = {
  ids: string[];
  unboundCompanyMemberIds: string[];
  approvedB2bPendingClaim: boolean;
};

// Candidate lookups may be broad, but only exact normalized whole-phone matches are authoritative.
// A capped query that might omit a candidate fails closed rather than minting for a partial result.
const CANDIDATE_LIMIT = 1000;
function checkedRows(result: { data: unknown[] | null; error: { message?: string } | null }, label: string): unknown[] | { error: string } {
  if (result.error || !result.data || result.data.length >= CANDIDATE_LIMIT) {
    console.error("[msg91] identity candidate lookup failed:", label);
    return { error: "identity_lookup_failed" };
  }
  return result.data;
}
async function phoneBoundUserIdsAmong(userIds: string[], normalized: string): Promise<Set<string> | { error: string }> {
  if (!userIds.length) return new Set();
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  if (userIds.length >= CANDIDATE_LIMIT) return { error: "identity_lookup_failed" };
  const result = await supabaseAdmin.from("users").select("id,phone,mobile_number,secondary_phones").in("id", userIds).limit(CANDIDATE_LIMIT);
  const rows = checkedRows(result, "b2b_user_bindings");
  if (!Array.isArray(rows)) return rows;
  return new Set(rows.filter((row: any) =>
    phoneEquals(row.phone, normalized) || phoneEquals(row.mobile_number, normalized) ||
    anyPhoneEquals(row.secondary_phones, normalized)
  ).map((row: any) => String(row.id)));
}
async function findPublicIdentityMatches(normalized: string): Promise<PublicIdentityMatchResult | { error: string }> {
  if (!supabaseAdmin) return { error: "service_role_unavailable" };
  const verified = canonicalIndianPhone(normalized);
  if (!verified) return { error: "phone_invalid" };
  const tail = verified.slice(-10);
  // Candidate discovery uses suffix search only as a prefilter; all returned fields are
  // subsequently validated with canonicalIndianPhone before they can influence identity.
  const pattern = `%${tail.split("").join("%")}%`; // match formatted candidates, then strict canonical equality
  const [userResult, appResult, companyResult] = await Promise.all([
    supabaseAdmin.from("users").select("id,phone,mobile_number,secondary_phones").or(`phone.ilike.${pattern},mobile_number.ilike.${pattern}`).limit(CANDIDATE_LIMIT),
    supabaseAdmin.from("b2b_applications").select("user_id,resolved_company_id,contact_phone,mobile_number").eq("status","approved").or(`contact_phone.ilike.${pattern},mobile_number.ilike.${pattern}`).limit(CANDIDATE_LIMIT),
    supabaseAdmin.from("companies").select("id,phone").ilike("phone",pattern).limit(CANDIDATE_LIMIT),
  ]);
  const users = checkedRows(userResult,"users");
  const apps = checkedRows(appResult,"applications");
  const companies = checkedRows(companyResult,"companies");
  if (!Array.isArray(users) || !Array.isArray(apps) || !Array.isArray(companies)) return { error: "identity_lookup_failed" };
  const ids = new Set<string>();
  for (const row of users as any[]) if (
    phoneEquals(row.phone,verified) || phoneEquals(row.mobile_number,verified) ||
    anyPhoneEquals(row.secondary_phones,verified)
  ) ids.add(String(row.id));
  // Array secondary_phones cannot be safely found via a text suffix search.
  // A separate exact-variant overlap covers the supported canonical representations.
  // Enumerate secondary-phone candidates page by page. An empty array is NOT null,
  // so a single capped .not(is,null) lookup rejects all sign-ins after 1,000 users.
  // Each page is checked for exact phone equality; incomplete scans fail closed.
  const SECONDARY_PAGE_SIZE = 500;
  const SECONDARY_MAX_PAGES = 200;
  let secondaryComplete = false;
  for (let page = 0; page < SECONDARY_MAX_PAGES; page++) {
    const from = page * SECONDARY_PAGE_SIZE;
    const secondary = await supabaseAdmin.from("users")
      .select("id,secondary_phones")
      .not("secondary_phones","is",null)
      .order("id", { ascending: true })
      .range(from, from + SECONDARY_PAGE_SIZE - 1);
    if (secondary.error || !secondary.data) return { error: "identity_lookup_failed" };
    for (const row of secondary.data) {
      if (anyPhoneEquals(row.secondary_phones,verified)) ids.add(String(row.id));
    }
    if (secondary.data.length < SECONDARY_PAGE_SIZE) {
      secondaryComplete = true;
      break;
    }
  }
  if (!secondaryComplete) return { error: "identity_lookup_failed" };
  const companyIds = new Set<string>();
  const b2bUserIds = new Set<string>();
  let approvedB2bPendingClaim = false;
  for (const app of apps as any[]) {
    if (!phoneEquals(app.contact_phone,verified) && !phoneEquals(app.mobile_number,verified)) continue;
    if (app.user_id) b2bUserIds.add(String(app.user_id));
    else approvedB2bPendingClaim = true;
    if (app.resolved_company_id) companyIds.add(String(app.resolved_company_id));
  }
  if (b2bUserIds.size) {
    const bound = await phoneBoundUserIdsAmong([...b2bUserIds],verified);
    if ("error" in bound) return bound;
    for (const id of bound) ids.add(id);
    if (bound.size < b2bUserIds.size) approvedB2bPendingClaim = true;
  }
  for (const company of companies as any[]) if (phoneEquals(company.phone,verified)) companyIds.add(String(company.id));
  const unboundCompanyMemberIds = new Set<string>();
  if (companyIds.size) {
    const companyUsers = await supabaseAdmin.from("users").select("id").in("company_id",[...companyIds]).limit(CANDIDATE_LIMIT);
    const rows = checkedRows(companyUsers,"company_members");
    if (!Array.isArray(rows)) return { error: "identity_lookup_failed" };
    for (const row of rows as any[]) unboundCompanyMemberIds.add(String(row.id));
  }
  return { ids:[...ids],unboundCompanyMemberIds:[...unboundCompanyMemberIds],approvedB2bPendingClaim };
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
      console.error("[msg91] pending_profile_create_failed:", error.code ?? "unknown");
    }
    // Upsert success is not proof of the intended binding: ignoreDuplicates can
    // silently leave an existing row unchanged. Read back the authoritative row.
    const checked = await supabaseAdmin.from("users").select("id,phone,mobile_number,secondary_phones").eq("id", userId).maybeSingle();
    if (checked.error || !checked.data) return { error: "pending_profile_create_failed" };
    if (!phoneEquals(checked.data.phone, phoneE164) &&
        !phoneEquals(checked.data.mobile_number, phoneE164) &&
        !anyPhoneEquals(checked.data.secondary_phones, phoneE164)) {
      return { error: "pending_profile_identity_conflict" };
    }
    return { ok: true };
  } catch (e) {
    console.error("[msg91] pending_profile_create_failed threw:", e instanceof Error ? e.name : "unknown");
    return { error: "pending_profile_create_failed" };
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
        if (authLookupError) {
          const status = (authLookupError as { status?: number }).status;
          if (status !== 404) return fail("identity_lookup_failed", 500);
          return fail("phone_linked_to_missing_auth_identity", 409);
        }
        if (!authLookup?.user) return fail("phone_linked_to_missing_auth_identity", 409);
        const bound = await ensureInternalEmail(authLookup.user.id, authLookup.user.email || "", normalized);
        if ("error" in bound) return fail(bound.error, 500);
        authRef = { userId: authLookup.user.id, email: bound.email };
      } else {
        const created = await createAuthUserForPhone(e164, normalized);
        if ("error" in created) return fail(created.error, 500);
        authRef = created;
        // An Auth record may predate this request following an uncertain profile write.
        // Treat it as pending, never as an existing approved B2B account.
        isNew = true;
        const pending = await ensurePendingProfile(authRef.userId, e164);
        if ("error" in pending) return fail(pending.error, 500);
      }

      const mint = await mintMagicTokenHash(authRef.email);
      if ("error" in mint) return fail(mint.error, 502);
      return new Response(JSON.stringify({ ok: true, type: "success", user_id: authRef.userId, email: authRef.email, phone: e164, is_new: isNew, approved_b2b_pending_claim: approvedB2bPendingClaim, token_hash: mint.tokenHash }), { status: 200, headers: jsonHeaders });
    }

    return new Response(JSON.stringify({ ok: false, error: "unknown mode" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[msg91-otp] fatal:", e instanceof Error ? e.name : "unknown");
    return new Response(JSON.stringify({ ok: false, error: "internal_error" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
