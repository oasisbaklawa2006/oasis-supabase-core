/**
 * WA450-D2: malformed provider status members must not abort the authenticated webhook batch.
 * Black-box tests run the real whatsapp-webhook entrypoint with stubbed serve + Supabase.
 */

const VERIFY_TOKEN = "unit-test-verify-token-not-production";
const ENTRYPOINT = new URL("./index.ts", import.meta.url);
const IMPORT_MAP = new URL("./testdata/import-map.json", import.meta.url);

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

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
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

async function withWebhook(
  mockEnv: Record<string, string>,
  run: (ctx: {
    post: (body: unknown) => Promise<Response>;
    statsPath: string;
  }) => Promise<void>,
) {
  const statsPath = await Deno.makeTempFile({ prefix: "wa-webhook-mock-stats-" });
  await Deno.writeTextFile(statsPath, "{}");

  const webhookPort = freePort();
  const child = new Deno.Command(Deno.execPath(), {
    args: [
      "run",
      "--quiet",
      "--allow-net",
      "--allow-env",
      "--allow-read",
      "--allow-write",
      `--import-map=${IMPORT_MAP.pathname}`,
      ENTRYPOINT.pathname,
    ],
    env: {
      WEBHOOK_TEST_PORT: String(webhookPort),
      SUPABASE_URL: "http://127.0.0.1:9",
      SUPABASE_SERVICE_ROLE_KEY: "unit-test-service-role-not-production",
      WHATSAPP_WEBHOOK_VERIFY_TOKEN: VERIFY_TOKEN,
      WEBHOOK_MOCK_STATS_FILE: statsPath,
      ...mockEnv,
    },
    stdout: "null",
    stderr: "piped",
  }).spawn();

  const base = `http://127.0.0.1:${webhookPort}/functions/v1/whatsapp-webhook?source=click2api&token=${VERIFY_TOKEN}`;
  try {
    let ready = false;
    for (let attempt = 0; attempt < 100 && !ready; attempt += 1) {
      try {
        const probe = await fetch(base, { method: "OPTIONS" });
        await probe.arrayBuffer();
        ready = probe.status === 204;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    if (!ready) throw new Error("webhook subprocess did not start");

    await run({
      statsPath,
      post: async (body) => {
        const res = await fetch(base, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        });
        assertSafeHeaders(res);
        return res;
      },
    });
  } finally {
    try {
      child.kill("SIGTERM");
    } catch { /* exited */ }
    await child.status;
    try {
      await Deno.remove(statsPath);
    } catch { /* ignore */ }
  }
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

Deno.test("WA450-D2 mixed valid status and inbound fails closed with 503 not 500", async () => {
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
    if (res.status !== 503) {
      throw new Error(`expected 503 mixed fail-closed, got ${res.status}`);
    }
    const body = await res.json();
    if (body.error !== "status_persistence_failed") {
      throw new Error(`unexpected error body: ${JSON.stringify(body)}`);
    }
    const stats = await readStats(statsPath);
    if ((stats.status_rpc_calls ?? 0) !== 1) {
      throw new Error("valid status should be durably attempted before mixed fail-closed");
    }
  });
});
