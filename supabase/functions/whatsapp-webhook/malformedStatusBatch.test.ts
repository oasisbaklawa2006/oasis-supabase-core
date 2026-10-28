/**
 * WA450-D2: malformed provider status members must not abort the authenticated webhook batch.
 * Black-box tests run the real whatsapp-webhook entrypoint with stubbed serve + Supabase.
 */

import { withWebhook as withSharedWebhook } from "./testdata/harness.ts";

type MetaMessage = { id: string; from: string; body: string };
function buildMetaPayload(
  messages: MetaMessage[],
  statuses: unknown[],
  extraEntries: { statuses?: unknown[]; messages?: MetaMessage[] }[] = [],
) {
  const primary = {
    changes: [{
      value: {
        messaging_product: "whatsapp",
        statuses: statuses,
        messages: messages.map((m) => ({
          id: m.id,
          from: m.from,
          timestamp: "1700000000",
          type: "text",
          text: { body: m.body },
        })),
        contacts: messages.map((m) => ({
          wa_id: m.from,
          profile: { name: "Fixture User" },
        })),
      },
    }],
  };
  const entry = [primary, ...extraEntries.map((slice) => ({
    changes: [{
      value: {
        messaging_product: "whatsapp",
        statuses: slice.statuses ?? [],
        messages: (slice.messages ?? []).map((m) => ({
          id: m.id,
          from: m.from,
          timestamp: "1700000000",
          type: "text",
          text: { body: m.body },
        })),
      },
    }],
  }))];
  return { entry };
}

function assertSafeHeaders(res: Response) {
  if (res.headers.get("Cache-Control") !== "no-store") {
    throw new Error("missing Cache-Control: no-store");
  }
  if (res.headers.get("X-Content-Type-Options") !== "nosniff") {
    throw new Error("missing X-Content-Type-Options: nosniff");
  }
  if (res.headers.get("Access-Control-Allow-Origin")) {
    throw new Error("wildcard CORS must not be present");
  }
}

async function readStats(statsPath: string): Promise<Record<string, number>> {
  try {
    return JSON.parse(await Deno.readTextFile(statsPath));
  } catch {
    return {};
  }
}

/** Shared subprocess harness, plus D2's standing assertion that every response carries safe headers. */
function withWebhook(
  mockEnv: Record<string, string>,
  run: (ctx: {
    post: (body: unknown) => Promise<Response>;
    statsPath: string;
  }) => Promise<void>,
) {
  return withSharedWebhook(mockEnv, ({ post, statsPath }) =>
    run({
      statsPath,
      post: async (body) => {
        const res = await post(body);
        assertSafeHeaders(res);
        return res;
      },
    }));
}

const defaultInbound: MetaMessage = {
  id: "wamid.FAKE_IN_BOUND_001",
  from: "000000000000",
  body: "fixture hello inbound",
};

Deno.test("WA450-D2 malformed-only status batch returns safe 200 (no valid status events)", async () => {
  await withWebhook({}, async ({ post }) => {
    const res = await post(buildMetaPayload([], [{ id: "wamid.FAKE_OUT_ORPHAN" }]));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (!body.ok) throw new Error(`expected ok discard path: ${JSON.stringify(body)}`);
  });
});

Deno.test("WA450-D2 malformed plus valid statuses persists only valid members", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
  }, async ({ post, statsPath }) => {
    const res = await post(buildMetaPayload([], [
      { id: "wamid.FAKE_OUT_ORPHAN" },
      { id: "wamid.FAKE_OUT_VALID", status: "delivered" },
    ]));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (body.event !== "status" || body.count !== 1) {
      throw new Error(`unexpected body: ${JSON.stringify(body)}`);
    }
    if (body.quarantined_status_elements !== 1) {
      throw new Error("expected one quarantined status element");
    }
    const stats = await readStats(statsPath);
    if ((stats.status_rpc_calls ?? 0) !== 1) {
      throw new Error(`expected 1 status rpc, got ${stats.status_rpc_calls ?? 0}`);
    }
  });
});

Deno.test("WA450-D2 malformed statuses with inbound still ingests inbound", async () => {
  await withWebhook({}, async ({ post, statsPath }) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [{ id: "wamid.FAKE_OUT_ORPHAN" }, null, "garbage"],
    ));
    if (res.status !== 200) throw new Error(`expected 200 inbound, got ${res.status}`);
    const body = await res.json();
    if (!body.ok) throw new Error(`expected inbound ok: ${JSON.stringify(body)}`);
    const stats = await readStats(statsPath);
    if ((stats.debug_webhook_inserts ?? 0) < 1) {
      throw new Error("expected inbound debug_webhooks insert");
    }
    if ((stats.status_rpc_calls ?? 0) !== 0) {
      throw new Error("no valid status events should call status rpc");
    }
  });
});

Deno.test("WA450-D2 malformed status in later entry still processes earlier valid status", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_A",
  }, async ({ post }) => {
    const res = await post(buildMetaPayload(
      [],
      [{ id: "wamid.FAKE_OUT_A", status: "sent" }],
      [{ statuses: [{ id: "wamid.FAKE_OUT_B" }] }],
    ));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (body.count !== 1 || body.quarantined_status_elements !== 1) {
      throw new Error(`unexpected batch body: ${JSON.stringify(body)}`);
    }
  });
});

Deno.test("WA450-D2 replay twice stays idempotent with safe headers", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
  }, async ({ post }) => {
    const payload = buildMetaPayload([], [
      { id: "wamid.FAKE_OUT_ORPHAN" },
      { id: "wamid.FAKE_OUT_VALID", status: "delivered" },
    ]);
    for (let i = 0; i < 2; i += 1) {
      const res = await post(payload);
      if (res.status !== 200) throw new Error(`replay ${i} expected 200, got ${res.status}`);
      const body = await res.json();
      if (body.event !== "status") throw new Error(`replay ${i} expected status event`);
    }
  });
});

Deno.test("WA450-D2 non-object and garbage status members are quarantined", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
  }, async ({ post }) => {
    const garbageStatus = "x".repeat(200);
    const longId = "wamid." + "Z".repeat(200);
    const res = await post(buildMetaPayload([], [
      { id: "wamid.FAKE_OUT_VALID", status: "read" },
      { id: longId, status: "sent" },
      { status: garbageStatus },
      42,
    ]));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (body.count !== 1) throw new Error(`expected one valid status: ${JSON.stringify(body)}`);
    if ((body.quarantined_status_elements ?? 0) < 3) {
      throw new Error("expected multiple quarantined elements");
    }
  });
});

Deno.test("WA450-D1+D2 malformed + valid status + inbound in one callback: audit, persist, ingest, one response", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
  }, async ({ post, statsPath }) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [
        { id: "wamid.FAKE_OUT_ORPHAN" },
        { id: "wamid.FAKE_OUT_VALID", status: "delivered" },
      ],
    ));
    if (res.status !== 200) throw new Error(`expected 200 for a fully processed mixed callback, got ${res.status}`);
    const body = await res.json();
    if (body.event !== "mixed" || body.inbound_processed !== 1) {
      throw new Error(`expected a processed mixed result: ${JSON.stringify(body)}`);
    }
    if (body.quarantined_status_elements !== 1) {
      throw new Error(`malformed member must be reported, not hidden: ${JSON.stringify(body)}`);
    }
    const stats = await readStats(statsPath);
    if ((stats.malformed_audit_inserts ?? 0) !== 1) throw new Error("malformed member needs one durable audit");
    if ((stats.status_rpc_calls ?? 0) !== 1) throw new Error("the valid status must be persisted exactly once");
    if ((stats.whatsapp_messages_inserts ?? 0) !== 1) throw new Error("the inbound message must be stored once");
    if ((stats.completion_receipts ?? 0) !== 1) throw new Error("the inbound message must be marked complete");
  });
});

Deno.test("WA450-D1+D2 replay of a mixed callback with a malformed member repeats no inbound effect", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
  }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload(
      [defaultInbound],
      [{ id: "wamid.FAKE_OUT_ORPHAN" }, { id: "wamid.FAKE_OUT_VALID", status: "delivered" }],
    );
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      const res = await post(payload);
      if (res.status !== 200) throw new Error(`delivery ${attempt}: expected 200, got ${res.status}`);
      await res.arrayBuffer();
    }
    const stats = await readStats(statsPath);
    if ((stats.whatsapp_messages_inserts ?? 0) !== 1) throw new Error("replay duplicated the durable row");
    if ((stats.whatsapp_buffer_inserts ?? 0) !== 1) throw new Error("replay duplicated the buffer row");
    if ((stats.malformed_audit_inserts ?? 0) !== 2) throw new Error("each delivery's malformed member is audited");
  });
});

Deno.test("WA450-D2 malformed audit persistence fails closed before status or inbound writes", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "wamid.FAKE_OUT_VALID",
    WEBHOOK_MOCK_FAIL_MALFORMED_AUDIT: "1",
  }, async ({ post, statsPath }) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [
        { id: "wamid.FAKE_OUT_ORPHAN" },
        { id: "wamid.FAKE_OUT_VALID", status: "delivered" },
      ],
    ));
    if (res.status !== 503) throw new Error(`expected 503 when audit fails, got ${res.status}`);
    const body = await res.json();
    if (body.error !== "malformed_status_audit_failed") throw new Error("missing fail-closed error");
    const stats = await readStats(statsPath);
    if ((stats.status_rpc_calls ?? 0) !== 0 || (stats.whatsapp_messages_inserts ?? 0) !== 0) {
      throw new Error("a failed audit cannot acknowledge or process sibling events");
    }
  });
});

Deno.test("WA450-D2 malformed callback persists PII-free audit before successful ACK", async () => {
  await withWebhook({}, async ({ post, statsPath }) => {
    const res = await post(buildMetaPayload([], [{ id: "wamid.FAKE_OUT_ORPHAN" }]));
    if (res.status !== 200) throw new Error(`expected 200 after durable audit, got ${res.status}`);
    const stats = await readStats(statsPath);
    if ((stats.malformed_audit_inserts ?? 0) !== 1) {
      throw new Error("malformed status was ACKed without durable audit insert");
    }
  });
});
