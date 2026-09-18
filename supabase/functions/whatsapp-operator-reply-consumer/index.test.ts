import { boundedMaxReplies } from "./index.ts";

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
