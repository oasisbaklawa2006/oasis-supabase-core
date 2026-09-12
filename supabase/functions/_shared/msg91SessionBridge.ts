export const MSG91_BRIDGE_UPSTREAM_TIMEOUT_MS = 10_000;

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

export type RequestBody = {
  mode?: string;
  accessToken?: string;
  phone?: string | null;
};

export type LegacyVerifiedResponse = {
  ok?: boolean;
  type?: string;
  user_id?: string;
  email?: string;
  phone?: string;
  is_new?: boolean;
  token_hash?: string | null;
  error?: string;
  reason?: string;
};

export type LegacyVerifyTransport = {
  status: number;
  ok: boolean;
  payload: LegacyVerifiedResponse | null;
};

export type BridgeSuccess = {
  ok: true;
  type: "success";
  user_id: string;
  phone: string;
  is_new: boolean;
  token_hash: string;
};

export type BridgeFailure = {
  ok: false;
  error: string;
};

export type BridgeResult = BridgeSuccess | BridgeFailure;

export type BridgeErrorCode =
  | "method_not_allowed"
  | "auth_service_unavailable"
  | "unsupported_mode"
  | "access_token_required"
  | "provider_verification_failed"
  | "verified_identity_unavailable"
  | "identity_reconciliation_failed"
  | "session_token_mint_failed"
  | "internal_error";

export function authResponseHeaders(): Record<string, string> {
  return {
    ...corsHeaders,
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Pragma": "no-cache",
    "X-Content-Type-Options": "nosniff",
  };
}

export function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: authResponseHeaders(),
  });
}

export function fail(error: BridgeErrorCode, status: number): Response {
  return jsonResponse({ ok: false, error }, status);
}

export function parseRequestBody(body: unknown): RequestBody {
  if (!body || typeof body !== "object") return {};
  return body as RequestBody;
}

export function validateBridgeRequest(
  body: RequestBody,
): BridgeFailure | { accessToken: string } {
  if (body.mode !== "verify_widget") {
    return { ok: false, error: "unsupported_mode" };
  }
  if (typeof body.accessToken !== "string" || !body.accessToken.trim()) {
    return { ok: false, error: "access_token_required" };
  }
  return { accessToken: body.accessToken.trim() };
}

export function buildUpstreamVerifyPayload(accessToken: string): string {
  return JSON.stringify({ mode: "verify_widget", accessToken });
}

export function upstreamVerifyPayloadExcludesClientPhone(payload: string): boolean {
  const parsed = JSON.parse(payload) as Record<string, unknown>;
  return !("phone" in parsed);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

/** Extracts identity only from the server-verified MSG91 provider payload. */
export function extractProviderVerifiedPhone(raw: unknown): string | null {
  const root = asRecord(raw);
  if (!root) return null;
  const message = asRecord(root.message);
  const data = asRecord(root.data);
  const dataUser = asRecord(data?.user);

  return firstString(
    typeof root.message === "string" ? root.message : null,
    typeof root.data === "string" ? root.data : null,
    message?.mobile,
    message?.phone,
    message?.identifier,
    message?.number,
    data?.mobile,
    data?.phone,
    data?.identifier,
    data?.number,
    root.mobile,
    root.phone,
    root.identifier,
    root.number,
    dataUser?.mobile,
    dataUser?.phone,
  );
}

/** Normalizes an Indian provider phone to E.164 or fails closed. */
export function normalizeIndianVerifiedPhone(raw: string | null | undefined): string | null {
  const digits = (raw || "").replace(/\D/g, "");
  if (digits.length === 10) return `+91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return `+${digits}`;
  return null;
}

/** Internal alias used only to mint the programmatic Supabase TokenHash. */
export function internalPhoneAliasEmail(phone: string): string | null {
  const normalized = normalizeIndianVerifiedPhone(phone);
  return normalized ? `${normalized.slice(1)}@phone.oasis.local` : null;
}

export function classifyVerifiedPayload(
  verified: LegacyVerifiedResponse | null,
): BridgeFailure | (LegacyVerifiedResponse & {
  ok: true;
  type: "success";
  user_id: string;
  email: string;
  phone: string;
}) {
  if (!verified || verified.ok !== true || verified.type !== "success") {
    return { ok: false, error: "provider_verification_failed" };
  }
  if (
    typeof verified.user_id !== "string" || !verified.user_id ||
    typeof verified.email !== "string" || !verified.email ||
    typeof verified.phone !== "string" || !verified.phone
  ) {
    return { ok: false, error: "verified_identity_unavailable" };
  }
  return verified as LegacyVerifiedResponse & {
    ok: true;
    type: "success";
    user_id: string;
    email: string;
    phone: string;
  };
}

export function sanitizeBridgeSuccess(
  verified: LegacyVerifiedResponse,
  tokenHash: string,
): BridgeSuccess {
  return {
    ok: true,
    type: "success",
    user_id: verified.user_id!,
    phone: verified.phone!,
    is_new: verified.is_new === true,
    token_hash: tokenHash,
  };
}

export function sanitizeBridgeResponseBody(
  body: BridgeResult,
): Record<string, unknown> {
  const allowed = new Set([
    "ok",
    "type",
    "user_id",
    "phone",
    "is_new",
    "token_hash",
    "error",
  ]);
  const sanitized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(body)) {
    if (allowed.has(key)) sanitized[key] = value;
  }
  return sanitized;
}

export function maskPhoneForLogs(phone: string): string {
  const digits = phone.replace(/\D/g, "");
  if (digits.length <= 4) return "****";
  return `${"*".repeat(Math.max(0, digits.length - 4))}${digits.slice(-4)}`;
}

export function extractTokenHashFromGenerateLink(data: {
  properties?: Record<string, unknown>;
}): string | null {
  const properties = data.properties || {};
  if (
    typeof properties.hashed_token === "string" && properties.hashed_token
  ) {
    return properties.hashed_token;
  }
  const actionLink = typeof properties.action_link === "string"
    ? properties.action_link
    : "";
  const tokenMatch = actionLink.match(/token_hash=([^&]+)/) ||
    actionLink.match(/[?#&]token=([^&]+)/);
  if (!tokenMatch) return null;
  return decodeURIComponent(tokenMatch[1]);
}

/**
 * Returns the legacy Edge payload even for a non-2xx response so the bridge can
 * distinguish one explicitly-governed compatibility condition from ordinary
 * provider/auth failures. Transport failures still collapse to null.
 */
export async function verifyThroughLegacyMsg91Detailed(
  supabaseUrl: string,
  serviceRoleKey: string,
  accessToken: string,
  fetchImpl: typeof fetch = fetch,
): Promise<LegacyVerifyTransport | null> {
  if (!supabaseUrl || !serviceRoleKey) return null;

  try {
    const response = await fetchImpl(
      `${supabaseUrl}/functions/v1/msg91-otp`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${serviceRoleKey}`,
          apikey: serviceRoleKey,
        },
        body: buildUpstreamVerifyPayload(accessToken),
        signal: AbortSignal.timeout(MSG91_BRIDGE_UPSTREAM_TIMEOUT_MS),
      },
    );
    const payload = (await response.json().catch(() => null)) as
      | LegacyVerifiedResponse
      | null;
    return { status: response.status, ok: response.ok, payload };
  } catch (_error) {
    return null;
  }
}

export async function verifyThroughLegacyMsg91(
  supabaseUrl: string,
  serviceRoleKey: string,
  accessToken: string,
  fetchImpl: typeof fetch = fetch,
): Promise<LegacyVerifiedResponse | null> {
  const result = await verifyThroughLegacyMsg91Detailed(
    supabaseUrl,
    serviceRoleKey,
    accessToken,
    fetchImpl,
  );
  return result?.ok ? result.payload : null;
}

export async function resolveBridgeSession(
  deps: {
    supabaseUrl: string;
    serviceRoleKey: string;
    mintTokenHash: (email: string) => Promise<string | null>;
    recoverLegacyPlaceholder?: (accessToken: string) => Promise<LegacyVerifiedResponse | null>;
    fetchImpl?: typeof fetch;
  },
  accessToken: string,
): Promise<BridgeResult> {
  const upstream = await verifyThroughLegacyMsg91Detailed(
    deps.supabaseUrl,
    deps.serviceRoleKey,
    accessToken,
    deps.fetchImpl,
  );

  let verified = upstream?.ok ? upstream.payload : null;
  if (
    !upstream?.ok &&
    upstream?.payload?.error === "phone_linked_to_missing_auth_identity"
  ) {
    if (!deps.recoverLegacyPlaceholder) {
      return { ok: false, error: "identity_reconciliation_failed" };
    }
    verified = await deps.recoverLegacyPlaceholder(accessToken);
    if (!verified) {
      return { ok: false, error: "identity_reconciliation_failed" };
    }
  }

  const classified = classifyVerifiedPayload(verified);
  if (!classified.ok) return classified;

  const success = classified;
  let tokenHash = typeof success.token_hash === "string" && success.token_hash
    ? success.token_hash
    : null;

  if (!tokenHash) {
    tokenHash = await deps.mintTokenHash(success.email);
    if (!tokenHash) return { ok: false, error: "session_token_mint_failed" };
  }

  return sanitizeBridgeSuccess(success, tokenHash);
}
