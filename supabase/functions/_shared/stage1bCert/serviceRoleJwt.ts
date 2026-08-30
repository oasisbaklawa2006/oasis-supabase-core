/** @file Mint service_role JWT for same-project Edge Function calls. */

function base64UrlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function signServiceRoleJwt(jwtSecret: string): Promise<string> {
  const header = base64UrlEncode(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64UrlEncode(JSON.stringify({
    role: "service_role",
    iss: "supabase",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(jwtSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/** Returns a Bearer token accepted by trustedServiceRoleAuthorization. */
export async function resolveServiceRoleBearerToken(): Promise<string> {
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (serviceRoleKey.split(".").length === 3) return serviceRoleKey;

  const jwtSecret = Deno.env.get("SUPABASE_JWT_SECRET") ??
    Deno.env.get("JWT_SECRET") ?? "";
  if (!jwtSecret) {
    throw new Error("SERVICE_ROLE_JWT_UNAVAILABLE:missing JWT secret");
  }
  return signServiceRoleJwt(jwtSecret);
}
