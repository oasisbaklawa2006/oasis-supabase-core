import { authenticateAndParseWebhook, detectWebhookStatusEvent } from "./whatsappWebhookBoundary.ts";

const encoder = new TextEncoder();

async function sign(body: Uint8Array, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bodyBuffer = body.slice().buffer;
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, bodyBuffer));
  const hex = Array.from(signature).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `sha256=${hex}`;
}

Deno.test("Click2API auth rejects invalid token before malformed JSON parsing", async () => {
  const result = await authenticateAndParseWebhook({
    rawBody: encoder.encode("not-json"),
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook?source=click2api&token=wrong",
    signatureHeader: null,
    verifyToken: "expected",
    appSecret: "unused",
  });
  if (result.ok || result.status !== 403 || result.code !== "verify_token_invalid") {
    throw new Error("invalid Click2API token did not win over JSON parsing");
  }
});

Deno.test("direct Meta auth rejects missing signature before malformed JSON parsing", async () => {
  const result = await authenticateAndParseWebhook({
    rawBody: encoder.encode("not-json"),
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook",
    signatureHeader: null,
    verifyToken: "unused",
    appSecret: "meta-secret",
  });
  if (result.ok || result.status !== 401 || result.code !== "signature_missing") {
    throw new Error("missing Meta signature did not win over JSON parsing");
  }
});

Deno.test("direct Meta auth rejects missing signature even when app secret is absent", async () => {
  const result = await authenticateAndParseWebhook({
    rawBody: encoder.encode('{"entry":[]}'),
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook",
    signatureHeader: null,
    verifyToken: "unused",
    appSecret: undefined,
  });
  if (result.ok || result.status !== 401 || result.code !== "signature_missing") {
    throw new Error("missing Meta signature must fail closed before app-secret readiness");
  }
});

Deno.test("authenticated malformed JSON is rejected without payload processing", async () => {
  const result = await authenticateAndParseWebhook({
    rawBody: encoder.encode("not-json"),
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook?source=click2api&token=expected",
    signatureHeader: null,
    verifyToken: "expected",
    appSecret: "unused",
  });
  if (result.ok || result.status !== 400 || result.code !== "invalid_json") {
    throw new Error("authenticated malformed JSON was not rejected");
  }
});

Deno.test("Click2API queue callback is classified as status", async () => {
  const body = encoder.encode(JSON.stringify({
    messaging_channel: "whatsapp",
    message: { queue_id: "q-1", message_status: "sent" },
    response: { messages: [{ id: "wamid-1" }] },
  }));
  const result = await authenticateAndParseWebhook({
    rawBody: body,
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook?source=click2api&token=expected",
    signatureHeader: null,
    verifyToken: "expected",
    appSecret: "unused",
  });
  if (!result.ok || result.statusEvent?.status !== "sent" || result.statusEvent.providerMessageId !== "wamid-1") {
    throw new Error("Click2API status callback was not classified correctly");
  }
});

Deno.test("nested Meta status callback is classified after valid signature", async () => {
  const secret = "meta-secret";
  const body = encoder.encode(JSON.stringify({
    entry: [{ changes: [{ value: { statuses: [{ id: "wamid-2", status: "delivered" }] } }] }],
  }));
  const result = await authenticateAndParseWebhook({
    rawBody: body,
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook",
    signatureHeader: await sign(body, secret),
    verifyToken: "unused",
    appSecret: secret,
  });
  if (!result.ok || result.statusEvent?.status !== "delivered" || result.statusEvent.providerMessageId !== "wamid-2") {
    throw new Error("Meta status callback was not classified correctly");
  }
});

Deno.test("ordinary authenticated payload is not mistaken for status", async () => {
  const body = encoder.encode(JSON.stringify({ message: "hello", from: "919999999999" }));
  const result = await authenticateAndParseWebhook({
    rawBody: body,
    requestUrl: "https://example.test/functions/v1/whatsapp-webhook?source=click2api&token=expected",
    signatureHeader: null,
    verifyToken: "expected",
    appSecret: "unused",
  });
  if (!result.ok || result.statusEvent !== null || result.payload.message !== "hello") {
    throw new Error("ordinary Click2API payload was altered or misclassified");
  }
});

Deno.test("detectWebhookStatusEvent ignores non-status payloads", () => {
  if (detectWebhookStatusEvent({ message: "hello" }) !== null) {
    throw new Error("non-status payload misclassified");
  }
});

Deno.test("Meta multi-entry, multi-change, multi-status callbacks preserve every ID and failure", async () => {
  const { detectWebhookStatusEvents } = await import("./whatsappWebhookBoundary.ts");
  const parsed = detectWebhookStatusEvents({
    entry: [
      { changes: [{ value: { statuses: [
        { id: "wamid.A", status: "delivered" },
        { id: "wamid.B", status: "failed", errors: [{ code: 131026, title: "private" }] },
      ] } }] },
      { changes: [{ value: { statuses: [{ id: "wamid.C", status: "read" }] } }] },
    ],
  });
  if (parsed.length !== 3) throw new Error("callback batch truncated");
  if (parsed.map((x) => x.providerMessageId).join(",") !== "wamid.A,wamid.B,wamid.C") {
    throw new Error("provider IDs not preserved");
  }
  if (parsed[1].providerErrorCode !== "131026") throw new Error("failure code lost");
});
Deno.test("malformed status members are quarantined without aborting valid siblings", async () => {
  const { detectWebhookStatusEventsWithQuarantine } = await import("./whatsappWebhookBoundary.ts");
  const parsed = detectWebhookStatusEventsWithQuarantine({
    entry: [{ changes: [{ value: { statuses: [
      { id: "wamid.A", status: "delivered" },
      { id: "wamid.B" },
      null,
      { id: "wamid.C", status: "x".repeat(100) },
    ] } }] }],
  });
  if (parsed.events.length !== 1 || parsed.events[0].providerMessageId !== "wamid.A") {
    throw new Error("valid status sibling was lost");
  }
  if (parsed.quarantined.length < 3) {
    throw new Error("expected quarantined malformed members");
  }
});

Deno.test("Meta signature is validated before accepting a status batch", async () => {
  const body = encoder.encode(JSON.stringify({entry:[{changes:[{value:{statuses:[
    {id:"wamid.one",status:"delivered"},{id:"wamid.two",status:"read"}
  ]}}]}]}));
  const signatureHeader = await sign(body, "test-secret");
  const good = await authenticateAndParseWebhook({
    rawBody: body, requestUrl: "https://example.test/whatsapp-webhook",
    signatureHeader, verifyToken: undefined, appSecret: "test-secret",
  });
  if (!good.ok || good.statusEvents.length !== 2) throw new Error("authenticated batch lost statuses");
  const bad = await authenticateAndParseWebhook({
    rawBody: body, requestUrl: "https://example.test/whatsapp-webhook",
    signatureHeader: "sha256=invalid", verifyToken: undefined, appSecret: "test-secret",
  });
  if (bad.ok || bad.status !== 401) throw new Error("unauthenticated batch passed");
});
