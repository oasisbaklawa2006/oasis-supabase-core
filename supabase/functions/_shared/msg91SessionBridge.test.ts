import {
  authResponseHeaders,
  buildUpstreamVerifyPayload,
  classifyVerifiedPayload,
  extractProviderVerifiedPhone,
  extractTokenHashFromGenerateLink,
  internalPhoneAliasEmail,
  maskPhoneForLogs,
  MSG91_BRIDGE_UPSTREAM_TIMEOUT_MS,
  normalizeIndianVerifiedPhone,
  parseRequestBody,
  resolveBridgeSession,
  sanitizeBridgeResponseBody,
  sanitizeBridgeSuccess,
  upstreamVerifyPayloadExcludesClientPhone,
  validateBridgeRequest,
  verifyThroughLegacyMsg91,
  verifyThroughLegacyMsg91Detailed,
} from "./msg91SessionBridge.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (actual !== expected) {
    throw new Error(message ?? `expected ${String(expected)}, received ${String(actual)}`);
  }
}

Deno.test("validateBridgeRequest accepts verify_widget with access token", () => {
  const parsed = validateBridgeRequest({
    mode: "verify_widget",
    accessToken: "  msg91-token  ",
  });
  assert(!("error" in parsed));
  assertEquals(parsed.accessToken, "msg91-token");
});

Deno.test("validateBridgeRequest rejects unsupported modes and missing tokens", () => {
  const unsupported = validateBridgeRequest({ mode: "email_login", accessToken: "token" });
  assert("error" in unsupported);
  if ("error" in unsupported) assertEquals(unsupported.error, "unsupported_mode");

  const missing = validateBridgeRequest({ mode: "verify_widget", accessToken: "  " });
  assert("error" in missing);
  if ("error" in missing) assertEquals(missing.error, "access_token_required");
});

Deno.test("upstream verify payload excludes client-supplied phone authority", () => {
  const payload = buildUpstreamVerifyPayload("provider-token");
  assert(upstreamVerifyPayloadExcludesClientPhone(payload));
  assertEquals(JSON.parse(payload).phone, undefined);
});

Deno.test("provider phone extraction accepts supported MSG91 payload shapes and normalizes fail-closed", () => {
  assertEquals(
    normalizeIndianVerifiedPhone(extractProviderVerifiedPhone({ type: "success", mobile: "9876543210" })),
    "+919876543210",
  );
  assertEquals(
    normalizeIndianVerifiedPhone(extractProviderVerifiedPhone({ data: { user: { phone: "+91-98765-43210" } } })),
    "+919876543210",
  );
  assertEquals(normalizeIndianVerifiedPhone("12345"), null);
  assertEquals(internalPhoneAliasEmail("+919876543210"), "919876543210@phone.oasis.local");
});

Deno.test("classifyVerifiedPayload fails closed on invalid, duplicate, orphan, and malformed upstream", () => {
  const nullResult = classifyVerifiedPayload(null);
  assert(!nullResult.ok);
  if (!nullResult.ok) assertEquals(nullResult.error, "provider_verification_failed");

  const expired = classifyVerifiedPayload({ ok: false, error: "expired_token" });
  assert(!expired.ok);
  if (!expired.ok) assertEquals(expired.error, "provider_verification_failed");

  const duplicate = classifyVerifiedPayload({
    ok: true,
    type: "success",
    reason: "duplicate_users",
  });
  assert(!duplicate.ok);
  if (!duplicate.ok) assertEquals(duplicate.error, "verified_identity_unavailable");

  const accepted = classifyVerifiedPayload({
    ok: true,
    type: "success",
    user_id: "user-1",
    email: "buyer@example.invalid",
    phone: "+919876543210",
  });
  assert(accepted.ok);
  if (accepted.ok) assertEquals(accepted.phone, "+919876543210");
});

Deno.test("sanitizeBridgeResponseBody strips provider internals and secrets", () => {
  const sanitized = sanitizeBridgeResponseBody({
    ok: true,
    type: "success",
    user_id: "user-1",
    phone: "+919876543210",
    is_new: false,
    token_hash: "hash-value",
    reason: "duplicate_users",
    email: "buyer@example.invalid",
    accessToken: "secret-token",
  } as never);
  assertEquals(sanitized.reason, undefined);
  assertEquals(sanitized.email, undefined);
  assertEquals(sanitized.accessToken, undefined);
  assertEquals(sanitized.token_hash, "hash-value");
});

Deno.test("auth responses are non-cacheable and hardened", () => {
  assertEquals(authResponseHeaders()["Cache-Control"], "no-store");
  assertEquals(authResponseHeaders()["Pragma"], "no-cache");
  assertEquals(authResponseHeaders()["X-Content-Type-Options"], "nosniff");
});

Deno.test("maskPhoneForLogs hides PII while preserving last four digits", () => {
  assertEquals(maskPhoneForLogs("+919876543210"), "********3210");
});

Deno.test("extractTokenHashFromGenerateLink prefers hashed_token over action link", () => {
  assertEquals(
    extractTokenHashFromGenerateLink({
      properties: { hashed_token: "preferred-hash" },
    }),
    "preferred-hash",
  );
  assertEquals(
    extractTokenHashFromGenerateLink({
      properties: {
        action_link: "https://example.test/auth/v1/verify?token_hash=link-hash",
      },
    }),
    "link-hash",
  );
});

Deno.test("verifyThroughLegacyMsg91 handles timeout and malformed provider transport", async () => {
  const timeoutFetch: typeof fetch = () =>
    Promise.reject(new DOMException("timeout", "TimeoutError"));
  assertEquals(
    await verifyThroughLegacyMsg91("https://preview.supabase.co", "service-role", "token", timeoutFetch),
    null,
  );

  const malformedFetch: typeof fetch = async () =>
    new Response("not-json", { status: 200 });
  assertEquals(
    await verifyThroughLegacyMsg91("https://preview.supabase.co", "service-role", "token", malformedFetch),
    null,
  );
});

Deno.test("detailed legacy verification preserves exact governed 409 reason without treating it as success", async () => {
  const collisionFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ ok: false, error: "phone_linked_to_missing_auth_identity" }), {
      status: 409,
      headers: { "Content-Type": "application/json" },
    });
  const result = await verifyThroughLegacyMsg91Detailed(
    "https://preview.supabase.co",
    "service-role",
    "verified-token",
    collisionFetch,
  );
  assert(result);
  assertEquals(result.ok, false);
  assertEquals(result.status, 409);
  assertEquals(result.payload?.error, "phone_linked_to_missing_auth_identity");
});

Deno.test("resolveBridgeSession succeeds for verified MSG91 handoff and mint fallback", async () => {
  const fetchImpl: typeof fetch = async (_input, init) => {
    assertEquals(init?.body, buildUpstreamVerifyPayload("verified-token"));
    return new Response(
      JSON.stringify({
        ok: true,
        type: "success",
        user_id: "user-1",
        email: "buyer@example.invalid",
        phone: "+919876543210",
        is_new: true,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };

  const result = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => "minted-hash",
      fetchImpl,
    },
    "verified-token",
  );

  assert(result.ok);
  if (result.ok) {
    assertEquals(result.token_hash, "minted-hash");
    assertEquals(result.phone, "+919876543210");
  }
});

Deno.test("resolveBridgeSession recovers only the exact legacy missing-Auth placeholder failure", async () => {
  let recoveryCalls = 0;
  const collisionFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ ok: false, error: "phone_linked_to_missing_auth_identity" }), {
      status: 409,
    });
  const result = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => "recovery-hash",
      recoverLegacyPlaceholder: async (token) => {
        recoveryCalls += 1;
        assertEquals(token, "verified-token");
        return {
          ok: true,
          type: "success",
          user_id: "canonical-user",
          email: "919876543210@phone.oasis.local",
          phone: "+919876543210",
          is_new: true,
        };
      },
      fetchImpl: collisionFetch,
    },
    "verified-token",
  );
  assertEquals(recoveryCalls, 1);
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.user_id, "canonical-user");
    assertEquals(result.token_hash, "recovery-hash");
  }
});

Deno.test("resolveBridgeSession never invokes placeholder recovery for unrelated upstream failures", async () => {
  let recoveryCalls = 0;
  const deniedFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ ok: false, error: "provider_verification_failed" }), {
      status: 401,
    });
  const result = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => null,
      recoverLegacyPlaceholder: async () => {
        recoveryCalls += 1;
        return null;
      },
      fetchImpl: deniedFetch,
    },
    "bad-token",
  );
  assertEquals(recoveryCalls, 0);
  assert(!result.ok);
  if (!result.ok) assertEquals(result.error, "provider_verification_failed");
});

Deno.test("resolveBridgeSession fails closed when exact placeholder recovery cannot reconcile", async () => {
  const collisionFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ ok: false, error: "phone_linked_to_missing_auth_identity" }), {
      status: 409,
    });
  const result = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => "must-not-mint",
      recoverLegacyPlaceholder: async () => null,
      fetchImpl: collisionFetch,
    },
    "verified-token",
  );
  assert(!result.ok);
  if (!result.ok) assertEquals(result.error, "identity_reconciliation_failed");
});

Deno.test("resolveBridgeSession preserves canonical upstream phone variants without client override", async () => {
  const variants = ["+919876543210", "919876543210", "+91-98765-43210"];
  for (const phone of variants) {
    const fetchImpl: typeof fetch = async () =>
      new Response(
        JSON.stringify({
          ok: true,
          type: "success",
          user_id: "user-1",
          email: "buyer@example.invalid",
          phone,
          token_hash: "existing-hash",
        }),
        { status: 200 },
      );
    const result = await resolveBridgeSession(
      {
        supabaseUrl: "https://preview.supabase.co",
        serviceRoleKey: "service-role",
        mintTokenHash: async () => null,
        fetchImpl,
      },
      "verified-token",
    );
    assert(result.ok);
    if (result.ok) assertEquals(result.phone, phone);
  }
});

Deno.test("resolveBridgeSession rejects provider verification failures and mint failures", async () => {
  const deniedFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ ok: false, error: "invalid_or_expired_token" }), {
      status: 401,
    });
  const denied = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => null,
      fetchImpl: deniedFetch,
    },
    "bad-token",
  );
  assert(!denied.ok);
  if (!denied.ok) assertEquals(denied.error, "provider_verification_failed");

  const orphanFetch: typeof fetch = async () =>
    new Response(
      JSON.stringify({
        ok: true,
        type: "success",
        user_id: "orphan-user",
        email: "orphan@example.invalid",
      }),
      { status: 200 },
    );
  const orphan = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => null,
      fetchImpl: orphanFetch,
    },
    "verified-token",
  );
  assert(!orphan.ok);
  if (!orphan.ok) assertEquals(orphan.error, "verified_identity_unavailable");

  const mintFetch: typeof fetch = async () =>
    new Response(
      JSON.stringify({
        ok: true,
        type: "success",
        user_id: "user-1",
        email: "buyer@example.invalid",
        phone: "+919876543210",
      }),
      { status: 200 },
    );
  const mintFailure = await resolveBridgeSession(
    {
      supabaseUrl: "https://preview.supabase.co",
      serviceRoleKey: "service-role",
      mintTokenHash: async () => null,
      fetchImpl: mintFetch,
    },
    "verified-token",
  );
  assert(!mintFailure.ok);
  if (!mintFailure.ok) assertEquals(mintFailure.error, "session_token_mint_failed");
});

Deno.test("parseRequestBody tolerates malformed JSON bodies safely", () => {
  assertEquals(Object.keys(parseRequestBody(null)).length, 0);
  assertEquals(Object.keys(parseRequestBody("not-an-object")).length, 0);
});

Deno.test("upstream timeout budget remains bounded", () => {
  assert(MSG91_BRIDGE_UPSTREAM_TIMEOUT_MS <= 10_000);
});

Deno.test("sanitizeBridgeSuccess never exposes email in customer-safe payload", () => {
  const payload = sanitizeBridgeSuccess(
    {
      ok: true,
      type: "success",
      user_id: "user-1",
      email: "buyer@example.invalid",
      phone: "+919876543210",
      is_new: false,
      token_hash: "hash",
    },
    "hash",
  );
  assertEquals((payload as Record<string, unknown>).email, undefined);
});
