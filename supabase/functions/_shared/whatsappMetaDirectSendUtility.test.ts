import {
  buildMetaDirectSendUtilityText,
  DIRECT_SEND_UTILITY_PURPOSES,
  readMetaDirectSendAcceptance,
} from "./whatsappMetaDirectSendUtility.ts";

function assertEqual(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message + ": actual and expected differ");
  }
}
function assertRejected(action: () => unknown, message: string) {
  let rejected = false;
  try {
    action();
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error(message);
}

const valid = {
  purpose: "ORDER_CONFIRMATION" as const,
  recipientE164: "+919999999999",
  body: "Order 123 is confirmed.",
};

Deno.test("utility payload uses exactly the Meta Direct Send contract", () => {
  assertEqual(
    buildMetaDirectSendUtilityText(valid),
    {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: "919999999999",
      type: "text",
      text: { body: "Order 123 is confirmed." },
      category: "utility",
    },
    "governed utility body",
  );
  assertEqual(
    Object.keys(buildMetaDirectSendUtilityText(valid)).sort(),
    ["category", "messaging_product", "recipient_type", "text", "to", "type"],
    "no provider token, unofficial Click2API fields or extra category",
  );
});

Deno.test("all approved purpose labels stay utility-only", () => {
  for (const purpose of DIRECT_SEND_UTILITY_PURPOSES) {
    const request = buildMetaDirectSendUtilityText({ ...valid, purpose });
    assertEqual(request.category, "utility", "fixed category");
  }
});

Deno.test("marketing, authentication, service and unknown purpose cannot enter utility lane", () => {
  for (
    const purpose of ["marketing", "authentication", "service", "PROMOTION"]
  ) {
    assertRejected(
      () =>
        buildMetaDirectSendUtilityText({
          ...valid,
          purpose: purpose as typeof valid.purpose,
        }),
      "unsupported purpose must reject",
    );
  }
});

Deno.test("missing or malformed recipient, including local/leading-zero numbers, rejects", () => {
  for (
    const recipientE164 of [
      "",
      "9999999999",
      "+019999999999",
      "+9199",
      "+1234567890123456",
      "+91 9999999999",
      "tel:+919999999999",
      "+91\n99999999",
    ]
  ) {
    assertRejected(
      () => buildMetaDirectSendUtilityText({ ...valid, recipientE164 }),
      "invalid recipient must reject",
    );
  }
});

Deno.test("empty, too-long or non-text bodies fail without truncation", () => {
  assertRejected(
    () => buildMetaDirectSendUtilityText({ ...valid, body: " \t " }),
    "whitespace-only is invalid",
  );
  assertRejected(
    () => buildMetaDirectSendUtilityText({ ...valid, body: "x".repeat(1025) }),
    "over-limit text is invalid",
  );
  assertRejected(
    () =>
      buildMetaDirectSendUtilityText({
        ...valid,
        body: 123 as unknown as string,
      }),
    "non-text body rejected",
  );
  const max = "x".repeat(1024);
  assertEqual(
    buildMetaDirectSendUtilityText({ ...valid, body: max }).text.body,
    max,
    "boundary preserved",
  );
  assertRejected(
    () => buildMetaDirectSendUtilityText({ ...valid, body: "🛒".repeat(513) }),
    "conservative UTF-16 length boundary",
  );
});

Deno.test("Meta single wamid acknowledgement is only provider acceptance", () => {
  assertEqual(
    readMetaDirectSendAcceptance({
      messaging_product: "whatsapp",
      contacts: [{ input: "9999999999", wa_id: "9999999999" }],
      messages: [{
        id: "wamid.SYNTHETIC123456",
        message_status: "accepted",
      }],
    }),
    {
      provider_message_id: "wamid.SYNTHETIC123456",
      provider_submission_status: "accepted",
    },
    "Meta wamid acknowledgement is not a delivery event",
  );
});

Deno.test("Meta quality hold is not converted into SENT or DELIVERED", () => {
  assertEqual(
    readMetaDirectSendAcceptance({
      messaging_product: "whatsapp",
      messages: [{
        id: "wamid.SYNTHETIC123456",
        message_status: "held_for_quality_assessment",
      }],
    }),
    {
      provider_message_id: "wamid.SYNTHETIC123456",
      provider_submission_status: "held_for_quality_assessment",
    },
    "quality hold must preserve Meta response truth",
  );
});

Deno.test("omitted submission status is recorded as unspecified, not fabricated", () => {
  assertEqual(
    readMetaDirectSendAcceptance({
      messaging_product: "whatsapp",
      messages: [{ id: "wamid.SYNTHETIC123456" }],
    }),
    {
      provider_message_id: "wamid.SYNTHETIC123456",
      provider_submission_status: "unspecified",
    },
    "unknown submission status remains unspecified",
  );
});

Deno.test("no queue UUID, bare id, malformed wamid or bare HTTP success qualifies", () => {
  for (
    const payload of [
      null,
      false,
      {},
      { success: true },
      { queue_id: "queue-uuid" },
      { messaging_product: "whatsapp", messages: [] },
      { messaging_product: "whatsapp", messages: [{ id: "opaque-uuid" }] },
      { messaging_product: "whatsapp", messages: [{ id: "wamid. " }] },
      { messaging_product: "whatsapp", messages: [{ id: "wamid.A B C D E" }] },
      {
        messaging_product: "messenger",
        messages: [{ id: "wamid.SYNTHETIC123456" }],
      },
    ]
  ) {
    assertEqual(
      readMetaDirectSendAcceptance(payload),
      null,
      "unverifiable acceptance rejected",
    );
  }
});

Deno.test("provider error, rejected status, or ambiguous batch cannot be accepted", () => {
  for (
    const payload of [
      {
        messaging_product: "whatsapp",
        error: { code: 100 },
        messages: [{ id: "wamid.SYNTHETIC123456" }],
      },
      {
        messaging_product: "whatsapp",
        messages: [{ id: "wamid.SYNTHETIC123456", message_status: "failed" }],
      },
      {
        messaging_product: "whatsapp",
        messages: [{
          id: "wamid.SYNTHETIC123456",
          message_status: "delivered",
        }],
      },
      {
        messaging_product: "whatsapp",
        messages: [
          { id: "wamid.SYNTHETIC123456" },
          { id: "wamid.SYNTHETIC654321" },
        ],
      },
    ]
  ) {
    assertEqual(
      readMetaDirectSendAcceptance(payload),
      null,
      "failed/multi-message result rejected",
    );
  }
});

Deno.test("extra category, template, provider options and tokens cannot enter utility request", () => {
  for (
    const extra of [
      { category: "marketing" },
      { category: "authentication" },
      { type: "image" },
      { template: { name: "synthetic" } },
      { access_token: "NEVER_A_REAL_TOKEN" },
      { auth: "Bearer SYNTHETIC" },
      { recipient: "other-user" },
    ]
  ) {
    assertRejected(
      () => buildMetaDirectSendUtilityText({ ...valid, ...extra }),
      "extraneous request fields must be rejected",
    );
  }
});

Deno.test("explicit negative Meta acceptance flags cannot be outweighed by a wamid", () => {
  for (
    const override of [
      { success: false },
      { ok: false },
      { status: "failed" },
      { status: "rejected" },
      { status: "undelivered" },
    ]
  ) {
    assertEqual(
      readMetaDirectSendAcceptance({
        messaging_product: "whatsapp",
        messages: [{ id: "wamid.SYNTHETIC123456", message_status: "accepted" }],
        ...override,
      }),
      null,
      "negative envelope cannot certify submission",
    );
  }
  assertEqual(
    readMetaDirectSendAcceptance({
      messaging_product: "whatsapp",
      messages: [{
        id: "wamid.SYNTHETIC123456",
        message_status: "accepted",
        error: { code: 100 },
      }],
    }),
    null,
    "message-local error cannot certify submission",
  );
});
