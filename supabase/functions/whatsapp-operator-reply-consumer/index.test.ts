import { boundedMaxReplies } from "./index.ts";
import { consumeAvailableReplies } from "../_shared/whatsappOperatorReplyDispatch.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (actual !== expected) {
    throw new Error(
      `${message}: expected=${String(expected)} actual=${String(actual)}`,
    );
  }
}

Deno.test("operator-reply consumer defaults to a bounded two-reply tick", () => {
  assertEquals(boundedMaxReplies(undefined), 2, "missing max_replies defaults");
  assertEquals(boundedMaxReplies("5"), 2, "non-numeric max_replies defaults");
  assertEquals(boundedMaxReplies(2.5), 2, "non-integer max_replies defaults");
});

Deno.test("operator-reply consumer clamps requested work to one through five replies", () => {
  assertEquals(boundedMaxReplies(-10), 1, "negative value clamps to one");
  assertEquals(boundedMaxReplies(0), 1, "zero clamps to one");
  assertEquals(boundedMaxReplies(1), 1, "one is accepted");
  assertEquals(boundedMaxReplies(3), 3, "in-range request is accepted");
  assertEquals(boundedMaxReplies(5), 5, "upper bound is accepted");
  assertEquals(boundedMaxReplies(99), 5, "large request clamps to five");
});

Deno.test("operator-reply consumer does not claim work when provider credentials are absent", async () => {
  const previousKey = Deno.env.get("CLICK2API_API_KEY");
  Deno.env.delete("CLICK2API_API_KEY");
  let rpcCalled = false;
  const fakeAdmin = {
    rpc() {
      rpcCalled = true;
      throw new Error("rpc must not be called without provider credentials");
    },
  };

  try {
    const result = await consumeAvailableReplies(
      fakeAdmin as never,
      "test-worker",
      2,
    );
    assertEquals(
      result.success,
      false,
      "missing provider credentials fail closed",
    );
    assertEquals(
      result.idle,
      true,
      "missing provider credentials leave queue idle",
    );
    assertEquals(
      result.processed,
      0,
      "missing provider credentials process nothing",
    );
    assertEquals(
      result.failed,
      1,
      "missing provider credentials report one configuration failure",
    );
    assertEquals(rpcCalled, false, "consumer must not claim an outbox row");
  } finally {
    if (previousKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", previousKey);
  }
});

Deno.test("HTTP_401 terminates the current consumer tick after one terminal failure", async () => {
  const previousKey = Deno.env.get("CLICK2API_API_KEY");
  const previousToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  const originalFetch = globalThis.fetch;
  let providerCalls = 0;
  let claims = 0;
  let failedWrites = 0;
  Deno.env.set("CLICK2API_API_KEY", "FIXTURE_NOT_A_LIVE_CREDENTIAL");
  Deno.env.delete("CLICK2API_ACCESS_TOKEN");

  // No real HTTP request can escape this test: all fetch calls are intercepted.
  globalThis.fetch = (_input, _init) => {
    providerCalls += 1;
    return Promise.resolve(
      new Response(
        JSON.stringify({ success: false, error: "token invalidated" }),
        {
          status: 401,
          headers: { "content-type": "application/json" },
        },
      ),
    );
  };
  const fakeAdmin = {
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "claim_whatsapp_operator_reply") {
        claims += 1;
        return {
          data: {
            id: "00000000-0000-4000-8000-000000000011",
            lease_token: "00000000-0000-4000-8000-000000000012",
            message_type: "TEXT",
            recipient_phone_e164: "+15555550123",
            message_body: "Consented synthetic test; never sent",
            template_name: null,
            template_language: null,
            message_origin: "STAFF",
            status: "SENDING",
          },
          error: null,
        };
      }
      if (name === "fail_whatsapp_operator_reply") {
        failedWrites += 1;
        assertEquals(args.p_error_code, "HTTP_401", "provider rejection code");
        assertEquals(
          args.p_acceptance_unknown,
          false,
          "rejection is not an unknown acceptance",
        );
        return { data: { status: "FAILED_FINAL" }, error: null };
      }
      throw new Error("Unexpected RPC: " + name);
    },
  };
  try {
    const result = await consumeAvailableReplies(
      fakeAdmin as never,
      "test-worker",
      5,
    );
    assertEquals(
      result.success,
      false,
      "authentication rejection fails the batch",
    );
    assertEquals(result.processed, 0, "no provider message is accepted");
    assertEquals(result.failed, 1, "one terminal failure counted");
    assertEquals(
      JSON.stringify(result.errors),
      '["FAILED_FINAL"]',
      "persisted terminal status is reported",
    );
    assertEquals(
      claims,
      1,
      "a second recipient must not be claimed after HTTP 401",
    );
    assertEquals(failedWrites, 1, "the failed row is recorded exactly once");
    assertEquals(providerCalls, 1, "a second provider request must not occur");
  } finally {
    globalThis.fetch = originalFetch;
    if (previousKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", previousKey);
    if (previousToken == null) Deno.env.delete("CLICK2API_ACCESS_TOKEN");
    else Deno.env.set("CLICK2API_ACCESS_TOKEN", previousToken);
  }
});

Deno.test("Click2API redirect does not forward credentials, retry, or claim another recipient", async () => {
  const previousKey = Deno.env.get("CLICK2API_API_KEY");
  const previousToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  const originalFetch = globalThis.fetch;
  let providerCalls = 0;
  let claims = 0;
  let quarantineWrites = 0;
  Deno.env.set("CLICK2API_API_KEY", "REDIRECT_TEST_KEY_NOT_REAL");
  Deno.env.set("CLICK2API_ACCESS_TOKEN", "REDIRECT_TEST_TOKEN_NOT_REAL");

  // The synthetic response advertises an untrusted second host. The fetch
  // stub must see redirect: manual so the real runtime never follows it.
  globalThis.fetch = (_input, init) => {
    providerCalls += 1;
    assertEquals(init?.redirect, "manual", "redirect following disabled");
    const headers = new Headers(init?.headers);
    assertEquals(headers.get("apikey"), "REDIRECT_TEST_KEY_NOT_REAL", "single intended host gets the API key");
    assertEquals(headers.get("Authorization"), "Bearer REDIRECT_TEST_TOKEN_NOT_REAL", "single intended host gets Bearer");
    return Promise.resolve(
      new Response(null, {
        status: 302,
        headers: { location: "https://untrusted.example/steal-headers" },
      }),
    );
  };

  const fakeAdmin = {
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "claim_whatsapp_operator_reply") {
        claims += 1;
        return {
          data: {
            id: "00000000-0000-4000-8000-000000000021",
            lease_token: "00000000-0000-4000-8000-000000000022",
            message_type: "TEXT",
            recipient_phone_e164: "+15555550123",
            message_body: "Synthetic redirect fixture; never sent",
            template_name: null,
            template_language: null,
            message_origin: "STAFF",
            status: "SENDING",
          },
          error: null,
        };
      }
      if (name === "fail_whatsapp_operator_reply") {
        quarantineWrites += 1;
        assertEquals(args.p_error_code, "HTTP_302_REDIRECT_BLOCKED", "redirect reason is non-secret");
        assertEquals(args.p_acceptance_unknown, true, "redirect must be quarantined");
        return { data: { status: "ACCEPTANCE_UNKNOWN" }, error: null };
      }
      throw new Error("Unexpected RPC: " + name);
    },
  };

  try {
    const result = await consumeAvailableReplies(
      fakeAdmin as never,
      "redirect-test-worker",
      5,
    );
    assertEquals(result.success, false, "redirect cannot be a successful send");
    assertEquals(result.processed, 0, "no provider acceptance recorded");
    assertEquals(result.failed, 1, "one quarantined message");
    assertEquals(JSON.stringify(result.errors), '["ACCEPTANCE_UNKNOWN"]', "unknown acceptance is non-retryable");
    assertEquals(providerCalls, 1, "no redirected or repeat provider request");
    assertEquals(claims, 1, "no second recipient claimed after redirect");
    assertEquals(quarantineWrites, 1, "one lease-preserving quarantine write");
  } finally {
    globalThis.fetch = originalFetch;
    if (previousKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", previousKey);
    if (previousToken == null) Deno.env.delete("CLICK2API_ACCESS_TOKEN");
    else Deno.env.set("CLICK2API_ACCESS_TOKEN", previousToken);
  }
});
