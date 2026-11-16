import { selectClick2ApiProviderMessageId } from "./whatsappProviderAcceptance.ts";

function assertSame(actual: unknown, expected: unknown, context: string) {
  if (actual !== expected) {
    throw new Error(`${context}: expected=${String(expected)}, got=${String(actual)}`);
  }
}

Deno.test("null, scalar, array and empty provider bodies cannot fabricate acceptance", () => {
  for (const input of [null, false, 2, "sent", [], {}, { messages: [] }]) {
    assertSame(selectClick2ApiProviderMessageId(input), null, "invalid envelope");
  }
});

Deno.test("Meta-style dashboard response supplies its canonical delivery identifier", () => {
  assertSame(
    selectClick2ApiProviderMessageId({
      messaging_product: "whatsapp",
      contacts: [{ wa_id: "REDACTED" }],
      messages: [{ id: "wamid.CONSENTED_FIXTURE", message_status: "accepted" }],
    }),
    "wamid.CONSENTED_FIXTURE",
    "Meta message ID",
  );
});

Deno.test("Meta wrapped response beats an unrelated transport queue UUID", () => {
  assertSame(
    selectClick2ApiProviderMessageId({
      queue_id: "00000000-0000-0000-0000-000000000001",
      response: {
        messages: [{ id: "wamid.WRAPPED_FIXTURE", message_status: "accepted" }],
      },
    }),
    "wamid.WRAPPED_FIXTURE",
    "Meta delivery ID prioritized",
  );
});

Deno.test("a multi-message response prioritizes wamid over opaque IDs", () => {
  assertSame(
    selectClick2ApiProviderMessageId({
      messages: [
        { id: "00000000-0000-0000-0000-000000000002" },
        { id: "wamid.LATE_FIXTURE" },
      ],
    }),
    "wamid.LATE_FIXTURE",
    "real WhatsApp message ID prioritized",
  );
});

Deno.test("explicit provider rejection cannot appear as an accepted message", () => {
  for (const input of [
    { success: false, message_id: "ghost" },
    { ok: false, response: { messages: [{ id: "wamid.GHOST" }] } },
    { response: { success: false, messages: [{ id: "wamid.GHOST" }] } },
    { message: { status: "failed" }, queue_id: "ghost" },
    { messages: [{ status: "rejected", id: "wamid.GHOST" }] },
  ]) {
    assertSame(
      selectClick2ApiProviderMessageId(input),
      null,
      "failed response does not prove acceptance",
    );
  }
});

Deno.test("legacy transport queue and direct message identifiers remain compatible", () => {
  assertSame(selectClick2ApiProviderMessageId({ queue_id: "uuid-opaque" }), "uuid-opaque", "queue fallback");
  assertSame(selectClick2ApiProviderMessageId({ message_id: "wamid.DIRECT" }), "wamid.DIRECT", "direct id");
  assertSame(selectClick2ApiProviderMessageId({ message: { id: "nested-id" } }), "nested-id", "nested id");
  assertSame(selectClick2ApiProviderMessageId({ queue_id: 17 }), 17, "numeric legacy ID");
});

Deno.test("unknown/empty identifiers and malformed nested items remain fail-closed", () => {
  assertSame(
    selectClick2ApiProviderMessageId({ messages: [null, {}, { id: " " }] }),
    null,
    "empty list ID",
  );
  assertSame(
    selectClick2ApiProviderMessageId({ messages: [{ id: "  wamid.WHITESPACE  " }] }),
    "wamid.WHITESPACE",
    "ID normalized",
  );
});
