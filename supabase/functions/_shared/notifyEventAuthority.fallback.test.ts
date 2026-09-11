import { buildApprovalNotification } from "./notifyEventAuthority.ts";

const assertEquals = (actual: unknown, expected: unknown, label: string) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
};

Deno.test("approval notification falls back to valid contact phone after invalid mobile", () => {
  const notification = buildApprovalNotification({
    id: "10000000-0000-4000-8000-000000000011",
    status: "approved",
    business_name: "FALLBACK CERT CO",
    contact_email: null,
    mobile_number: "123",
    contact_phone: "9891162212",
    assigned_price_tier: "GOLD",
  });

  assertEquals(notification.phone, "919891162212", "normalized fallback phone");
});

Deno.test("approval notification does not invent a phone when all candidates are invalid", () => {
  const notification = buildApprovalNotification({
    id: "10000000-0000-4000-8000-000000000012",
    status: "approved",
    business_name: "INVALID PHONE CERT CO",
    contact_email: "buyer@example.com",
    mobile_number: "123",
    contact_phone: "555",
    assigned_price_tier: null,
  });

  assertEquals(notification.phone, null, "invalid candidates remain rejected");
});
