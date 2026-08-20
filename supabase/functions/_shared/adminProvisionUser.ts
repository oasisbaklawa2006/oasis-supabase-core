// Pure, unit-testable helpers for admin-provision-user/index.ts. Kept
// separate from the Deno.serve handler so they can be exercised with
// `deno test` without a live Supabase project.

export type ProvisionMode = "invite" | "service_credential";

export type ProvisionRequest = {
  email: string;
  displayName?: string;
  roleKey: string;
  department?: string;
  designation?: string;
  mode: ProvisionMode;
};

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const STRING_FIELDS = [
  "email",
  "displayName",
  "roleKey",
  "department",
  "designation",
] as const;
type StringField = typeof STRING_FIELDS[number];

const readStringField = (
  payload: Record<string, unknown>,
  field: StringField,
): string | undefined => {
  if (!STRING_FIELDS.includes(field)) return undefined;
  const value = payload[field];
  return typeof value === "string" ? value : undefined;
};

const requirePayloadObject = (body: unknown): Record<string, unknown> => {
  if (typeof body !== "object" || body === null) {
    throw new Error("request body must be a JSON object");
  }
  return body as Record<string, unknown>;
};

const requireEmail = (payload: Record<string, unknown>): string => {
  const email = readStringField(payload, "email")?.trim() ?? "";
  if (!email || !EMAIL_PATTERN.test(email)) {
    throw new Error("a valid email is required");
  }
  return email;
};

const requireRoleKey = (payload: Record<string, unknown>): string => {
  const roleKey = readStringField(payload, "roleKey")?.trim() ?? "";
  if (!roleKey) {
    throw new Error("roleKey is required");
  }
  return roleKey;
};

const readMode = (payload: Record<string, unknown>): ProvisionMode =>
  payload.mode === "service_credential" ? "service_credential" : "invite";

export const parseRequest = (body: unknown): ProvisionRequest => {
  const payload = requirePayloadObject(body);
  return {
    email: requireEmail(payload),
    displayName: readStringField(payload, "displayName"),
    roleKey: requireRoleKey(payload),
    department: readStringField(payload, "department"),
    designation: readStringField(payload, "designation"),
    mode: readMode(payload),
  };
};

const BASE64URL_DASH = /-/g;
const BASE64URL_UNDERSCORE = /_/g;

// Reads the same "aal" claim public.has_step_up_auth() reads via
// auth.jwt() ->> 'aal'. The caller is expected to have already verified the
// token's signature (e.g. via supabase-js auth.getUser()) before decoding
// its payload here -- this function does not itself verify anything.
export const decodeJwtAal = (token: string): string | undefined => {
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  try {
    const normalized = parts[1].replace(BASE64URL_DASH, "+").replace(
      BASE64URL_UNDERSCORE,
      "/",
    );
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const payload = JSON.parse(atob(padded));
    return typeof payload.aal === "string" ? payload.aal : undefined;
  } catch {
    return undefined;
  }
};

export const generateStrongPassword = (): string => {
  // 24 bytes of CSPRNG entropy, base64url-encoded -- well above any
  // reasonable minimum length and never derived from any predictable input.
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  const base64 = btoa(String.fromCharCode(...bytes));
  return base64.replaceAll("+", "-").replaceAll("/", "_").replace(/[=]+$/, "");
};

export const allowedOrigin = (
  configured: string | undefined,
  requestOrigin: string | null,
): string | null => {
  const trimmed = configured?.trim();
  if (!trimmed || !requestOrigin || requestOrigin !== trimmed) return null;
  return requestOrigin;
};
