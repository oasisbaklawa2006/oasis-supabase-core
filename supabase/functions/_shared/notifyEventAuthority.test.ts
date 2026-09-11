import {
  approvalChannels,
  approvalIdempotencyKey,
  buildApprovalNotification,
  nextApprovalAttempt,
  normalizeEmail,
  normalizePhone,
} from "./notifyEventAuthority.ts";

const assertEquals = (actual: unknown, expected: unknown, label: string) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
};

Deno.test("approval notification uses authoritative approved application data", () => {
  const notification = buildApprovalNotification({
    id: "10000000-0000-4000-8000-000000000001",
    status: "approved",
    business_name: "CERT B2B CO",
    contact_email: " Buyer@Example.com ",
    mobile_number: "98911 62212",
    contact_phone: null,
    assigned_price_tier: "GOLD",
  });

  assertEquals(notification.email, "buyer@example.com", "normalized email");
  assertEquals(notification.phone, "919891162212", "normalized phone");
  assertEquals(
    approvalChannels(notification),
    ["email", "whatsapp"],
    "channel fanout",
  );
  if (
    !notification.message.includes("CERT B2B CO") ||
    !notification.message.includes("GOLD")
  ) {
    throw new Error(
      "approval message must contain authoritative business/tier context",
    );
  }
});

Deno.test("unapproved application is fail closed", () => {
  let failed = false;
  try {
    buildApprovalNotification({
      id: "10000000-0000-4000-8000-000000000002",
      status: "pending",
      business_name: "PENDING CO",
      contact_email: "p@example.com",
      mobile_number: "9891162212",
      contact_phone: null,
      assigned_price_tier: null,
    });
  } catch (error) {
    failed = error instanceof Error &&
      error.message === "application_not_approved";
  }
  if (!failed) {
    throw new Error(
      "pending application must not produce approval notification",
    );
  }
});

Deno.test("channel identity is deterministic and retry safe", () => {
  const id = "10000000-0000-4000-8000-000000000003";
  assertEquals(
    approvalIdempotencyKey(id, "email"),
    `b2b-access-approved:${id}:email`,
    "email key",
  );
  assertEquals(
    approvalIdempotencyKey(id, "whatsapp"),
    `b2b-access-approved:${id}:whatsapp`,
    "whatsapp key",
  );
});

Deno.test("invalid or non-Indian recipient values are dropped rather than guessed", () => {
  assertEquals(normalizeEmail("not-an-email"), null, "invalid email");
  assertEquals(normalizeEmail("a@"), null, "missing email domain");
  assertEquals(
    normalizeEmail("@example.com"),
    null,
    "missing email local part",
  );
  assertEquals(normalizePhone("123"), null, "invalid phone");
  assertEquals(
    normalizePhone("2025550123"),
    null,
    "ambiguous non-Indian 10-digit phone",
  );
  assertEquals(
    normalizePhone("09891162212"),
    "919891162212",
    "India trunk prefix",
  );
  assertEquals(
    normalizePhone("+91 98911 62212"),
    "919891162212",
    "explicit India country code",
  );
});

Deno.test("approval retry count increments and fails closed at max attempts", () => {
  assertEquals(nextApprovalAttempt(0, 5), {
    allowed: true,
    nextAttemptCount: 1,
    maxAttempts: 5,
  }, "first attempt");
  assertEquals(nextApprovalAttempt(4, 5), {
    allowed: true,
    nextAttemptCount: 5,
    maxAttempts: 5,
  }, "last allowed attempt");
  assertEquals(nextApprovalAttempt(5, 5), {
    allowed: false,
    nextAttemptCount: 6,
    maxAttempts: 5,
  }, "exhausted");
});
