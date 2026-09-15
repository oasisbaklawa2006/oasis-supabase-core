import { boundedMaxJobs } from "./index.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (actual !== expected) {
    throw new Error(
      `${message}: expected=${String(expected)} actual=${String(actual)}`,
    );
  }
}

Deno.test("consumer defaults to a bounded three-job tick", () => {
  assertEquals(boundedMaxJobs(undefined), 3, "missing max_jobs defaults");
  assertEquals(boundedMaxJobs("5"), 3, "non-numeric max_jobs defaults");
  assertEquals(boundedMaxJobs(2.5), 3, "non-integer max_jobs defaults");
});

Deno.test("consumer clamps requested work to one through five jobs", () => {
  assertEquals(boundedMaxJobs(-10), 1, "negative value clamps to one");
  assertEquals(boundedMaxJobs(0), 1, "zero clamps to one");
  assertEquals(boundedMaxJobs(1), 1, "one is accepted");
  assertEquals(boundedMaxJobs(4), 4, "in-range request is accepted");
  assertEquals(boundedMaxJobs(5), 5, "upper bound is accepted");
  assertEquals(boundedMaxJobs(99), 5, "large request clamps to five");
});
