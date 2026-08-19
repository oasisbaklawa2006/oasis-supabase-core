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

export function parseRequest(body: unknown): ProvisionRequest {
  if (typeof body !== "object" || body === null) {
    throw new Error("request body must be a JSON object");
  }
  const b = body as Record<string, unknown>;
  const email = typeof b.email === "string" ? b.email.trim() : "";
  const roleKey = typeof b.roleKey === "string" ? b.roleKey.trim() : "";
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("a valid email is required");
  }
  if (!roleKey) {
    throw new Error("roleKey is required");
  }
  const mode: ProvisionMode = b.mode === "service_credential" ? "service_credential" : "invite";
  return {
    email,
    displayName: typeof b.displayName === "string" ? b.displayName : undefined,
    roleKey,
    department: typeof b.department === "string" ? b.department : undefined,
    designation: typeof b.designation === "string" ? b.designation : undefined,
    mode,
  };
}

// Reads the same "aal" claim public.has_step_up_auth() reads via
// auth.jwt() ->> 'aal'. The caller is expected to have already verified the
// token's signature (e.g. via supabase-js auth.getUser()) before decoding
// its payload here -- this function does not itself verify anything.
export function decodeJwtAal(token: string): string | undefined {
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  try {
    const normalized = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const payload = JSON.parse(atob(padded));
    return typeof payload.aal === "string" ? payload.aal : undefined;
  } catch {
    return undefined;
  }
}

export function generateStrongPassword(): string {
  // 24 bytes of CSPRNG entropy, base64url-encoded -- well above any
  // reasonable minimum length and never derived from any predictable input.
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

export function allowedOrigin(configured: string | undefined, requestOrigin: string | null): string | null {
  const trimmed = configured?.trim();
  if (!trimmed || !requestOrigin || requestOrigin !== trimmed) return null;
  return requestOrigin;
}
