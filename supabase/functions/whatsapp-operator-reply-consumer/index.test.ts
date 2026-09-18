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
