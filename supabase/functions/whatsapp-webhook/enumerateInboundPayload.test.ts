import {
  enumerateInboundPayloads,
  payloadContainsInboundMessages,
} from "./inboundPayloadUtils.ts";

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

Deno.test("enumerateInboundPayloads yields one synthetic payload per inbound message", () => {
  const payload = {
    entry: [{
      changes: [{
        value: {
          messages: [
            { id: "wamid.FAKE_IN_1", from: "000000000000", text: { body: "one" } },
            { id: "wamid.FAKE_IN_2", from: "000000000000", text: { body: "two" } },
          ],
        },
      }],
    }],
  };
  const singles = enumerateInboundPayloads(payload);
  if (singles.length !== 2) throw new Error(`expected 2 singles, got ${singles.length}`);
  const ids = singles.map((single) => {
    const root = single as { entry: { changes: { value: { messages: { id: string }[] } }[] }[] };
    return root.entry[0].changes[0].value.messages[0].id;
  });
  if (ids[0] !== "wamid.FAKE_IN_1" || ids[1] !== "wamid.FAKE_IN_2") {
    throw new Error("message order not preserved");
  }
});
