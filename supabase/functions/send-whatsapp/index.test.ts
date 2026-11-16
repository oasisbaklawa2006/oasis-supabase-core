import { sendViaClick2API } from "./index.ts";

function assertEquals(actual: unknown, expected: unknown, label: string) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected=${String(expected)} actual=${String(actual)}`,
    );
  }
}
type FakeFetch = (url: string, init: RequestInit) => Promise<Response>;

async function withTestCredentials(action: () => Promise<void>): Promise<void> {
  const previousKey = Deno.env.get("CLICK2API_API_KEY");
  const previousToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  Deno.env.set("CLICK2API_API_KEY", "WA100_TEST_ONLY_NOT_A_REAL_KEY");
  Deno.env.delete("CLICK2API_ACCESS_TOKEN");
  try {
    await action();
  } finally {
    if (previousKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", previousKey);
    if (previousToken == null) Deno.env.delete("CLICK2API_ACCESS_TOKEN");
    else Deno.env.set("CLICK2API_ACCESS_TOKEN", previousToken);
  }
}

Deno.test("HTTP 401 is terminal; no retries, no MSG91 fallback", async () => {
  await withTestCredentials(async () => {
    let calls = 0;
    const fake: FakeFetch = async () => {
      await Promise.resolve();
      calls++;
      return new Response(
        JSON.stringify({ success: false, error: "token invalidated" }),
        { status: 401 },
      );
    };
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(calls, 1, "exactly one provider invocation");
    assertEquals(result.success, false, "401 rejected");
    assertEquals(result.acceptanceUnknown, undefined, "rejection is known");
    assertEquals(result.error, "HTTP_401_REJECTED", "redacted response");
  });
});

Deno.test("successful Meta response accepts its canonical wamid, not delivery", async () => {
  await withTestCredentials(async () => {
    let observedUrl = "";
    let observedBody = "";
    const fake: FakeFetch = async (url, init) => {
      await Promise.resolve();
      observedUrl = url;
      observedBody = String(init.body);
      return new Response(
        JSON.stringify({
          messaging_product: "whatsapp",
          messages: [{ id: "wamid.WA100_TEST", message_status: "accepted" }],
        }),
        { status: 200 },
      );
    };
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(
      observedUrl,
      "https://crm.click2api.in/api/v1/messages",
      "approved CRM endpoint",
    );
    assertEquals(result.success, true, "accepted by provider");
    assertEquals(result.messageId, "wamid.WA100_TEST", "canonical Meta ID");
    assertEquals(result.status, 200, "provider HTTP status");
    assertEquals(
      (JSON.parse(observedBody) as { type: string }).type,
      "text",
      "outbound text format",
    );
  });
});

Deno.test("known queue ID remains transport acceptance, never delivered", async () => {
  await withTestCredentials(async () => {
    const fake: FakeFetch = async () =>
      await new Response(
        JSON.stringify({
          success: true,
          queue_id: "00000000-0000-0000-0000-000000000024",
        }),
        { status: 200 },
      );
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(result.success, true, "queue acknowledgement accepted");
    assertEquals(
      result.messageId,
      "00000000-0000-0000-0000-000000000024",
      "queue ID",
    );
    assertEquals(result.acceptanceUnknown, undefined, "queue acceptance known");
  });
});

Deno.test("HTTP 200 without an identifier is quarantined as acceptance unknown", async () => {
  await withTestCredentials(async () => {
    let calls = 0;
    const fake: FakeFetch = async () => {
      await Promise.resolve();
      calls++;
      return new Response(JSON.stringify({ status: "queued" }), {
        status: 200,
      });
    };
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(calls, 1, "no internal retry");
    assertEquals(result.success, false, "no fabricated acceptance");
    assertEquals(result.acceptanceUnknown, true, "acceptance unknown");
  });
});

Deno.test("transport timeout cannot automatically trigger a second send", async () => {
  await withTestCredentials(async () => {
    let calls = 0;
    const fake: FakeFetch = async () => {
      await Promise.resolve();
      calls++;
      throw new Error("WA100 TEST simulated lost provider acknowledgement");
    };
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(calls, 1, "only one dispatch attempt");
    assertEquals(result.success, false, "not accepted without evidence");
    assertEquals(result.acceptanceUnknown, true, "unknown acceptance");
    assertEquals(result.error, "ACCEPTANCE_UNKNOWN", "redacted error");
  });
});

Deno.test("provider failure inside a success HTTP response cannot hide under a queue ID", async () => {
  await withTestCredentials(async () => {
    const fake: FakeFetch = async () =>
      await new Response(
        JSON.stringify({
          queue_id: "00000000-0000-0000-0000-000000000025",
          messages: [{ id: "wamid.WA100_REJECT", message_status: "rejected" }],
        }),
        { status: 200 },
      );
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      fake,
    );
    assertEquals(result.success, false, "nested rejection");
    assertEquals(result.error, "PROVIDER_MESSAGE_REJECTED", "rejection reason");
  });
});

Deno.test("no credentials means no provider call", async () => {
  const previousKey = Deno.env.get("CLICK2API_API_KEY");
  Deno.env.delete("CLICK2API_API_KEY");
  let called = false;
  try {
    const result = await sendViaClick2API(
      "919800000000",
      "WA100 fixture",
      async () => {
        await Promise.resolve();
        called = true;
        throw new Error("Unexpected real dispatch");
      },
    );
    assertEquals(called, false, "no provider call");
    assertEquals(
      result.error,
      "PROVIDER_NOT_CONFIGURED",
      "unconfigured credential",
    );
  } finally {
    if (previousKey == null) Deno.env.delete("CLICK2API_API_KEY");
    else Deno.env.set("CLICK2API_API_KEY", previousKey);
  }
});
