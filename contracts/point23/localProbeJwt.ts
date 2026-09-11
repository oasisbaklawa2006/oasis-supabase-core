/** Sign a local Supabase demo JWT for disposable transport probes only. */

function base64UrlEncode(bytes: Uint8Array): string {
  const bin = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlEncodeJson(value: Record<string, unknown>): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

export async function signLocalSupabaseJwt(
  sub: string,
  role: "authenticated" | "service_role",
  secret: string,
): Promise<string> {
  const header = base64UrlEncodeJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlEncodeJson({
    iss: "supabase-demo",
    role,
    sub,
    exp: Math.floor(Date.now() / 1000) + 3600,
  });
  const data = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)),
  );
  return `${data}.${base64UrlEncode(signature)}`;
}
