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
      new Response(JSON.stringify({ success: false, error: "token invalidated" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    );
  };
  const fakeAdmin = {
    async rpc(name: string, args: Record<string, unknown>) {
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
        assertEquals(args.p_acceptance_unknown, false, "rejection is not an unknown acceptance");
        return { data: { status: "FAILED_FINAL" }, error: null };
      }
      throw new Error("Unexpected RPC: " + name);
    },
  };
  try {
    const result = await consumeAvailableReplies(fakeAdmin as never, "test-worker", 5);
    assertEquals(result.success, false, "authentication rejection fails the batch");
    assertEquals(result.processed, 0, "no provider message is accepted");
    assertEquals(result.failed, 1, "one terminal failure counted");
    assertEquals(JSON.stringify(result.errors), '["FAILED_FINAL"]', "persisted terminal status is reported");
    assertEquals(claims, 1, "a second recipient must not be claimed after HTTP 401");
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
