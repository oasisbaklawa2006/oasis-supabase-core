import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  corsHeaders,
  extractProviderVerifiedPhone,
  extractTokenHashFromGenerateLink,
  fail,
  internalPhoneAliasEmail,
  jsonResponse,
  normalizeIndianVerifiedPhone,
  parseRequestBody,
  resolveBridgeSession,
  sanitizeBridgeResponseBody,
  type LegacyVerifiedResponse,
  validateBridgeRequest,
} from "../_shared/msg91SessionBridge.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const MSG91_AUTH_KEY = Deno.env.get("MSG91_AUTH_KEY") || "";
const supabaseAdmin = SUPABASE_URL && SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  : null;

type PlaceholderPreflight = {
  placeholder_user_id?: string | null;
  application_id?: string | null;
  eligible?: boolean;
  reason?: string | null;
};

type PlaceholderReconcile = {
  reconciled?: boolean;
  replayed?: boolean;
  canonical_user_id?: string | null;
  application_id?: string | null;
};

type CanonicalIdentityState = "present" | "absent" | "unknown";

function firstRpcRow<T>(data: unknown): T | null {
  if (Array.isArray(data)) return (data[0] as T | undefined) ?? null;
  if (data && typeof data === "object") return data as T;
  return null;
}

async function mintRedirectIndependentTokenHash(email: string): Promise<string | null> {
  if (!supabaseAdmin) return null;

  try {
    const { data, error } = await supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (error || !data) return null;
    return extractTokenHashFromGenerateLink(data);
  } catch (error) {
    console.error(
      "[msg91-session-bridge] token mint failed",
      error instanceof Error ? error.name : "unknown",
    );
    return null;
  }
}

/**
 * Re-verifies the same provider access token directly only after the legacy
 * upstream has returned the exact governed missing-Auth-placeholder failure.
 * Client-supplied phone data is never used as identity authority.
 */
async function verifyProviderPhoneForPlaceholderRecovery(
  accessToken: string,
): Promise<string | null> {
  if (!MSG91_AUTH_KEY) return null;
  try {
    const response = await fetch(
      "https://control.msg91.com/api/v5/widget/verifyAccessToken",
      {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          authkey: MSG91_AUTH_KEY,
          "access-token": accessToken,
        }),
        signal: AbortSignal.timeout(10_000),
      },
    );
    const payload = await response.json().catch(() => null);
    if (!response.ok || !payload || payload.type !== "success") return null;
    return normalizeIndianVerifiedPhone(extractProviderVerifiedPhone(payload));
  } catch (error) {
    console.error(
      "[msg91-session-bridge] recovery provider verification failed",
      error instanceof Error ? error.name : "unknown",
    );
    return null;
  }
}

async function reconcilePlaceholderOnce(
  phone: string,
  placeholderUserId: string,
  newAuthUserId: string,
): Promise<PlaceholderReconcile | null> {
  if (!supabaseAdmin) return null;
  const { data, error } = await supabaseAdmin.rpc(
    "reconcile_b2b_pending_phone_placeholder_v1",
    {
      p_verified_phone: phone,
      p_expected_placeholder_user_id: placeholderUserId,
      p_new_auth_user_id: newAuthUserId,
    },
  );
  if (error) return null;
  return firstRpcRow<PlaceholderReconcile>(data);
}

async function canonicalPublicIdentityState(
  userId: string,
  verifiedPhone: string,
): Promise<CanonicalIdentityState> {
  if (!supabaseAdmin) return "unknown";
  const { data, error } = await supabaseAdmin
    .from("users")
    .select("id,phone,mobile_number,role,is_active,deleted_at")
    .eq("id", userId)
    .maybeSingle();
  if (error) return "unknown";
  if (!data) return "absent";

  const storedPhone = normalizeIndianVerifiedPhone(data.phone || data.mobile_number || "");
  const role = String(data.role || "").toUpperCase();
  const canonical = storedPhone === verifiedPhone &&
    ["PENDING", "PENDING_BUYER", "B2B_BUYER"].includes(role) &&
    data.is_active !== false && !data.deleted_at;

  return canonical ? "present" : "unknown";
}

/**
 * Removes an Auth identity created only for a failed reconciliation attempt.
 * Supabase admin deletion reports failures in the resolved `error` field, so
 * both returned errors and thrown transport failures are retried before the
 * bridge gives up. The caller never mints a session token on this path.
 */
async function cleanupCreatedAuthUser(userId: string): Promise<boolean> {
  if (!supabaseAdmin) return false;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const { error } = await supabaseAdmin.auth.admin.deleteUser(userId);
      if (!error) return true;
      if (attempt === 2) {
        console.error(
          "[msg91-session-bridge] auth cleanup failed",
          error.name || "auth_error",
        );
      }
    } catch (error) {
      if (attempt === 2) {
        console.error(
          "[msg91-session-bridge] auth cleanup failed",
          error instanceof Error ? error.name : "unknown",
        );
      }
    }

    if (attempt < 2) {
      await new Promise((resolve) => setTimeout(resolve, 100 * (attempt + 1)));
    }
  }

  return false;
}

/**
 * Compatibility recovery for Core #292. This path is reachable only when the
 * canonical legacy verifier says one public phone identity exists but its UUID
 * has no Auth identity. A service-only DB preflight must independently prove
 * that row is a non-authoritative onboarding placeholder before any Auth user is
 * created. The DB reconciliation then re-validates every invariant atomically.
 */
async function recoverLegacyPendingPlaceholder(
  accessToken: string,
): Promise<LegacyVerifiedResponse | null> {
  if (!supabaseAdmin) return null;

  const verifiedPhone = await verifyProviderPhoneForPlaceholderRecovery(accessToken);
  if (!verifiedPhone) return null;

  const { data: inspectData, error: inspectError } = await supabaseAdmin.rpc(
    "inspect_b2b_pending_phone_placeholder_v1",
    { p_verified_phone: verifiedPhone },
  );
  const preflight = firstRpcRow<PlaceholderPreflight>(inspectData);
  if (
    inspectError || !preflight?.eligible || !preflight.placeholder_user_id ||
    !preflight.application_id
  ) {
    return null;
  }

  const aliasEmail = internalPhoneAliasEmail(verifiedPhone);
  if (!aliasEmail) return null;

  const { data: created, error: createError } = await supabaseAdmin.auth.admin.createUser({
    phone: verifiedPhone,
    phone_confirm: true,
    email: aliasEmail,
    email_confirm: true,
  });
  if (createError || !created?.user) return null;

  const newAuthUserId = created.user.id;
  let reconciled: PlaceholderReconcile | null = null;

  // The RPC is transactionally idempotent. A bounded retry handles an ambiguous
  // HTTP transport outcome without creating a second Auth identity.
  for (let attempt = 0; attempt < 2; attempt += 1) {
    reconciled = await reconcilePlaceholderOnce(
      verifiedPhone,
      preflight.placeholder_user_id,
      newAuthUserId,
    );
    if (
      reconciled?.canonical_user_id === newAuthUserId &&
      (reconciled.reconciled === true || reconciled.replayed === true)
    ) {
      break;
    }
  }

  const reconciliationSucceeded = reconciled?.canonical_user_id === newAuthUserId &&
    (reconciled.reconciled === true || reconciled.replayed === true);
  const canonicalState = reconciliationSucceeded
    ? "present" as const
    : await canonicalPublicIdentityState(newAuthUserId, verifiedPhone);

  if (!reconciliationSucceeded && canonicalState !== "present") {
    // Cleanup is allowed only when the canonical public identity is definitively
    // absent. Read failures or conflicting rows are "unknown" and fail closed
    // without deleting the provider-confirmed Auth identity.
    if (canonicalState === "absent") {
      await cleanupCreatedAuthUser(newAuthUserId);
    }
    return null;
  }

  return {
    ok: true,
    type: "success",
    user_id: newAuthUserId,
    email: aliasEmail,
    phone: verifiedPhone,
    is_new: true,
    token_hash: null,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return fail("method_not_allowed", 405);
  if (!supabaseAdmin) return fail("auth_service_unavailable", 503);

  try {
    const body = parseRequestBody(await req.json());
    const validated = validateBridgeRequest(body);
    if ("error" in validated) {
      return fail(validated.error, 400);
    }

    const result = await resolveBridgeSession(
      {
        supabaseUrl: SUPABASE_URL,
        serviceRoleKey: SERVICE_ROLE_KEY,
        mintTokenHash: mintRedirectIndependentTokenHash,
        recoverLegacyPlaceholder: recoverLegacyPendingPlaceholder,
      },
      validated.accessToken,
    );

    if (!result.ok) {
      const status = result.error === "provider_verification_failed"
        ? 401
        : result.error === "identity_reconciliation_failed"
        ? 409
        : result.error === "verified_identity_unavailable" ||
            result.error === "session_token_mint_failed"
        ? 502
        : 500;
      return fail(result.error, status);
    }

    return jsonResponse(sanitizeBridgeResponseBody(result));
  } catch (error) {
    console.error(
      "[msg91-session-bridge] fatal",
      error instanceof Error ? error.name : "unknown",
    );
    return fail("internal_error", 500);
  }
});
