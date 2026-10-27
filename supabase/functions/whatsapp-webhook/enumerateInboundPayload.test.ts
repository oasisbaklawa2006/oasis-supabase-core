import {
  enumerateInboundPayloads,
  payloadContainsInboundMessages,
} from "./inboundPayloadUtils.ts";

function messageIdFromSingle(payload: unknown): string {
  const root = payload as {
    entry: { changes: { value: { messages: { id: string }[] } }[] }[];
  };
  return root.entry[0].changes[0].value.messages[0].id;
}

Deno.test("payloadContainsInboundMessages detects nested Meta messages", () => {
  const payload = {
    entry: [{
      changes: [
        { value: { statuses: [{ id: "wamid.FAKE_OUT_1", status: "delivered" }] } },
        { value: { messages: [{ id: "wamid.FAKE_IN_1", from: "000000000000" }] } },
      ],
    }],
  };
  if (!payloadContainsInboundMessages(payload)) {
    throw new Error("expected inbound detection");
  }
});

Deno.test("enumerateInboundPayloads isolates each entry/change/message for extractPayloadFields", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "ENTRY_A",
        changes: [{
          field: "messages",
          value: {
            messages: [
              { id: "wamid.FAKE_IN_A1", from: "000000000001", text: { body: "alpha" } },
            ],
            contacts: [{ wa_id: "000000000001", profile: { name: "A" } }],
            statuses: [{ id: "wamid.FAKE_OUT_A", status: "sent" }],
          },
        }],
      },
      {
        id: "ENTRY_B",
        changes: [
          { value: { statuses: [{ id: "wamid.FAKE_OUT_B", status: "delivered" }] } },
          {
            value: {
              messages: [
                { id: "wamid.FAKE_IN_B1", from: "000000000002", text: { body: "bravo-one" } },
                { id: "wamid.FAKE_IN_B2", from: "000000000002", text: { body: "bravo-two" } },
              ],
              contacts: [{ wa_id: "000000000002", profile: { name: "B" } }],
            },
          },
        ],
      },
    ],
  };

  const singles = enumerateInboundPayloads(payload);
  if (singles.length !== 3) throw new Error(`expected 3 singles, got ${singles.length}`);

  const ids = singles.map(messageIdFromSingle);
  if (ids.join(",") !== "wamid.FAKE_IN_A1,wamid.FAKE_IN_B1,wamid.FAKE_IN_B2") {
    throw new Error(`unexpected message order: ${ids.join(",")}`);
  }

  for (const single of singles) {
    const root = single as { entry: unknown[] };
    if (root.entry.length !== 1) throw new Error("synthetic payload must contain exactly one entry");
    const entry = root.entry[0] as { changes: { value: Record<string, unknown> }[] };
    if (entry.changes.length !== 1) throw new Error("synthetic payload must contain exactly one change");
    const value = entry.changes[0].value;
    if (!Array.isArray(value.messages) || value.messages.length !== 1) {
      throw new Error("synthetic payload must contain exactly one message");
    }
    if (Array.isArray(value.statuses)) {
      throw new Error("statuses must be stripped from inbound-only synthetic payloads");
    }
  }
});
