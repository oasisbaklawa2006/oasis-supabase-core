import {
  safeWebhookHeaders,
  verifyChallengeToken,
  verifyMetaSignature,
} from "./whatsappWebhookSecurity.ts";

Deno.test("verifyChallengeToken accepts exact token", () => {
  const result = verifyChallengeToken("expected-token", "expected-token");
  if (!result.ok) throw new Error(`expected success, got ${result.code}`);
});

Deno.test("verifyChallengeToken rejects missing and invalid tokens", () => {
  const missing = verifyChallengeToken(null, "expected-token");
  if (missing.ok || missing.status !== 403) throw new Error("missing token was not rejected");

  const invalid = verifyChallengeToken("wrong-token", "expected-token");
  if (invalid.ok || invalid.status !== 403) throw new Error("invalid token was not rejected");
});

Deno.test("verifyMetaSignature accepts correct HMAC and rejects invalid signatures", async () => {
  const secret = "test-app-secret";
  const body = new TextEncoder().encode('{"object":"whatsapp_business_account"}');
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  const hex = Array.from(signature).map((byte) => byte.toString(16).padStart(2, "0")).join("");

  const valid = await verifyMetaSignature(body, `sha256=${hex}`, secret);
  if (!valid.ok) throw new Error(`valid signature rejected: ${valid.code}`);

  const invalid = await verifyMetaSignature(body, `sha256=${"00".repeat(32)}`, secret);
  if (invalid.ok || invalid.status !== 401) throw new Error("invalid signature was not rejected");
});

Deno.test("safeWebhookHeaders do not expose browser CORS", () => {
  const headers = safeWebhookHeaders();
  if ("Access-Control-Allow-Origin" in headers) throw new Error("wildcard CORS must not be present");
  if (headers["Cache-Control"] !== "no-store") throw new Error("no-store header missing");
});
