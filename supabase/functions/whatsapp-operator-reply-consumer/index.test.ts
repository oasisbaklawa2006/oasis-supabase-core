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

Deno.test("preview runtime never claims an operator-reply row, even with provider credentials", async () => {
  const oldUrl = Deno.env.get("SUPABASE_URL");
  const oldDeployment = Deno.env.get("DENO_DEPLOYMENT_ID");
  const oldKey = Deno.env.get("CLICK2API_API_KEY");
  let rpcCalls = 0;
  const admin = {
    rpc() {
      rpcCalls += 1;
      throw new Error("preview must never claim or fail provider queue items");
    },
  };
  try {
    Deno.env.set("SUPABASE_URL", "https://stkvyotdkysieuvpuues.supabase.co");
    Deno.env.set(
      "DENO_DEPLOYMENT_ID",
      "stkvyotdkysieuvpuues_11111111-2222-4333-8444-555555555555_12",
    );
    Deno.env.set("CLICK2API_API_KEY", "synthetic-nonproduction-key");
    const result = await consumeAvailableReplies(
      admin as never,
      "preview-no-send",
      5,
    );
    assertEquals(result.success, false, "preview explicitly denied");
    assertEquals(result.idle, true, "preview leaves queue idle");
    assertEquals(result.processed, 0, "no outbound work");
    assertEquals(result.failed, 1, "one explicit denial");
    assertEquals(
      (result.errors as string[])[0],
      "PROVIDER_EGRESS_BLOCKED",
      "opaque provider denial",
    );
    assertEquals(rpcCalls, 0, "no service-role queue mutation");
  } finally {
    if (oldUrl == null) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", oldUrl);
    if (oldDeployment == null) Deno.env.delete("DENO_DEPLOYMENT_ID");
    else Deno.env.set("DENO_DEPLOYMENT_ID", oldDeployment);
    if (oldKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", oldKey);
  }
});
