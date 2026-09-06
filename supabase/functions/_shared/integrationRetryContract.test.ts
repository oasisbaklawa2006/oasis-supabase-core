import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  classifyHttpStatus,
  executeWithBoundedRetry,
  IntegrationError,
  isRetryableIntegrationError,
  isTransientHttpStatus,
} from "./integrationRetryContract.ts";

Deno.test("shared integration retry contract classifies transient HTTP statuses", () => {
  for (const status of [408, 429, 500, 503, 599]) {
    assertEquals(isTransientHttpStatus(status), true);
    assertEquals(classifyHttpStatus(status), "retryable");
  }

  for (const status of [400, 401, 404, 422]) {
    assertEquals(isTransientHttpStatus(status), false);
    assertEquals(classifyHttpStatus(status), "permanent");
  }
});

Deno.test("bounded retry executes permanent failures without retrying", async () => {
  let calls = 0;

  await assertRejects(
    () =>
      executeWithBoundedRetry({
        policy: { maxAttempts: 3, retryDelaysMs: [1] },
        operation: async () => {
          calls += 1;
          throw new IntegrationError("PROVIDER_400", "permanent");
        },
      }),
    IntegrationError,
    "PROVIDER_400",
  );

  assertEquals(calls, 1);
});

Deno.test("bounded retry recovers after transient failures", async () => {
  let calls = 0;

  const value = await executeWithBoundedRetry({
    policy: { maxAttempts: 3, retryDelaysMs: [0, 0] },
    operation: async () => {
      calls += 1;
      if (calls < 2) {
        throw new IntegrationError("PROVIDER_503", "retryable");
      }
      return "ok";
    },
  });

  assertEquals(value, "ok");
  assertEquals(calls, 2);
});

Deno.test("bounded retry exhausts attempts and fails closed", async () => {
  let calls = 0;

  await assertRejects(
    () =>
      executeWithBoundedRetry({
        policy: { maxAttempts: 2, retryDelaysMs: [0] },
        operation: async () => {
          calls += 1;
          throw new IntegrationError("PROVIDER_503", "retryable");
        },
      }),
    IntegrationError,
    "PROVIDER_503",
  );

  assertEquals(calls, 2);
});

Deno.test("bounded retry honors total budget before another attempt", async () => {
  let calls = 0;
  let now = 0;

  await assertRejects(
    () =>
      executeWithBoundedRetry({
        policy: { maxAttempts: 3, retryDelaysMs: [25], totalBudgetMs: 10 },
        operation: async () => {
          calls += 1;
          throw new IntegrationError("PROVIDER_503", "retryable");
        },
        now: () => now,
        sleep: async (milliseconds) => {
          now += milliseconds;
        },
      }),
    IntegrationError,
    "PROVIDER_503",
  );

  assertEquals(calls, 1);
});

Deno.test("retryable integration error classifier is explicit", () => {
  assertEquals(
    isRetryableIntegrationError(new IntegrationError("X", "retryable")),
    true,
  );
  assertEquals(
    isRetryableIntegrationError(new IntegrationError("X", "permanent")),
    false,
  );
  assertEquals(isRetryableIntegrationError(new Error("generic")), false);
});
