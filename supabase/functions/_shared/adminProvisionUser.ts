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

export type ListedUser = {
  id: string;
  email?: string;
};

export type ListedUserPage = {
  users: ListedUser[];
  total?: number;
};

export type ListUsersPage = (
  page: number,
  perPage: number,
) => Promise<ListedUserPage>;

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

type StringField =
  | "email"
  | "displayName"
  | "roleKey"
  | "department"
  | "designation";

// No dynamic property access: each field is read through its own literal
// branch, so there is no bracket-notation `obj[key]` pattern to flag.
const readStringField = (
  payload: Record<string, unknown>,
  field: StringField,
): string | undefined => {
  let value: unknown;
  switch (field) {
    case "email":
      value = payload.email;
      break;
    case "displayName":
      value = payload.displayName;
      break;
    case "roleKey":
      value = payload.roleKey;
      break;
    case "department":
      value = payload.department;
      break;
    case "designation":
      value = payload.designation;
      break;
    default:
      value = undefined;
      break;
  }
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
  const roleKey = readStringField(payload, "roleKey")?.trim().toLowerCase() ??
    "";
  if (!roleKey) {
    throw new Error("roleKey is required");
  }
  return roleKey;
};

const readMode = (payload: Record<string, unknown>): ProvisionMode => {
  const mode = payload.mode;
  if (mode === undefined || mode === null) return "invite";
  if (mode === "invite" || mode === "service_credential") return mode;
  throw new Error('mode must be "invite" or "service_credential"');
};

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

// Exhaustively scans the paginated Auth Admin user list for an email match.
// The caller supplies the page loader so pagination semantics remain directly
// unit-testable without importing the Deno.serve handler or a live Supabase
// client. A full page advances to the next page; a short page or the reported
// total ends the scan. This removes the former fixed 1,000-user ceiling while
// keeping the lookup deterministic and fail-closed at the caller boundary.
export const findExistingUserAcrossPages = async (
  email: string,
  listPage: ListUsersPage,
  perPage = 1000,
): Promise<{ id: string } | null> => {
  const target = email.toLowerCase();
  let inspected = 0;

  for (let page = 1;; page += 1) {
    const result = await listPage(page, perPage);
    const existing = result.users.find(
      (candidate) => candidate.email?.toLowerCase() === target,
    );
    if (existing) return { id: existing.id };

    inspected += result.users.length;
    if (result.users.length < perPage) return null;
    if (
      typeof result.total === "number" &&
      result.total >= 0 &&
      inspected >= result.total
    ) {
      return null;
    }
  }
};

const BASE64URL_DASH = /-/g;
const BASE64URL_UNDERSCORE = /_/g;

// Reads the same "aal" claim public.has_step_up_auth() reads via
// auth.jwt() ->> 'aal'. The caller is expected to have already verified the
// token's signature (e.g. via supabase-js auth.getUser()) before decoding
// its payload here -- this function does not itself verify anything.
// Mirrors the Edge Function gate that pairs staff_provisionable_roles.requires_step_up
// with the same JWT "aal" claim public.has_step_up_auth() reads in SQL.
export const stepUpBlocksGrant = (
  roleRequiresStepUp: boolean,
  aal: string | undefined,
): string | null => {
  if (roleRequiresStepUp && aal !== "aal2") {
    return "this role requires a step-up (AAL2) session on the granting admin";
  }
  return null;
};

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
