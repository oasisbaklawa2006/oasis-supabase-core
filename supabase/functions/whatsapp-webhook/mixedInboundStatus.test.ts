/**
 * Black-box WA450-D1 regression tests for mixed inbound+status callbacks.
 * Runs the real whatsapp-webhook entrypoint in a subprocess with stubbed serve + Supabase.
 */

const VERIFY_TOKEN = "unit-test-verify-token-not-production";
const ENTRYPOINT = new URL("./index.ts", import.meta.url);
const IMPORT_MAP = new URL("./testdata/import-map.json", import.meta.url);

type MetaMessage = { id: string; from: string; body: string };
type MetaStatus = { id: string; status: string };

function buildMetaPayload(messages: MetaMessage[], statuses: MetaStatus[]) {
  return {
    entry: [{
      changes: [{
        value: {
          messaging_product: "whatsapp",
          statuses: statuses.map((s) => ({ id: s.id, status: s.status, timestamp: "1700000000" })),
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
    }],
  };
}

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
}

async function withWebhook(
  mockEnv: Record<string, string>,
  run: (post: (body: unknown) => Promise<Response>) => Promise<void>,
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
    if (!ready) {
      throw new Error("webhook subprocess did not start (OPTIONS probe never returned 204)");
    }

    await run(async (body) => {
      return await fetch(base, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    });
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      // already exited
    }
    await child.status;
    try {
      await Deno.remove(statsPath);
    } catch {
      // ignore
    }
  }
}

const defaultInbound: MetaMessage = {
  id: "wamid.FAKE_IN_BOUND_001",
  from: "000000000000",
  body: "fixture hello inbound",
};

Deno.test("statuses-only multi-status including failed and undelivered returns 200", async () => {
  await withWebhook({
    WEBHOOK_MOCK_MATCHED_PROVIDER_IDS:
      "wamid.FAKE_OUT_1,wamid.FAKE_OUT_2,wamid.FAKE_OUT_3,wamid.FAKE_OUT_4",
  }, async (post) => {
    const payload = buildMetaPayload([], [
      { id: "wamid.FAKE_OUT_1", status: "sent" },
      { id: "wamid.FAKE_OUT_2", status: "delivered" },
      { id: "wamid.FAKE_OUT_3", status: "failed" },
      { id: "wamid.FAKE_OUT_4", status: "undelivered" },
    ]);
    const res = await post(payload);
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (body.event !== "status" || body.count !== 4) {
      throw new Error(`unexpected status body: ${JSON.stringify(body)}`);
    }
  });
});

Deno.test("messages-only inbound is processed (not blocked by status short-circuit)", async () => {
  await withWebhook({}, async (post) => {
    const res = await post(buildMetaPayload([defaultInbound], []));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (!body.ok) throw new Error(`expected ok inbound body: ${JSON.stringify(body)}`);
  });
});

Deno.test("mixed messages and statuses returns 200 and processes both legs", async () => {
  await withWebhook({}, async (post) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [
        { id: "wamid.FAKE_OUT_1", status: "delivered" },
        { id: "wamid.FAKE_OUT_2", status: "failed" },
      ],
    ));
    if (res.status !== 200) throw new Error(`expected 200 mixed, got ${res.status}`);
    const body = await res.json();
    if (body.event !== "mixed" || body.inbound_processed !== 1) {
      throw new Error(`expected mixed success body: ${JSON.stringify(body)}`);
    }
    if (!body.inbound?.ok) throw new Error("inbound leg missing ok=true");
  });
});

Deno.test("mixed callback replayed twice stays idempotent at HTTP 200", async () => {
  await withWebhook(
    { WEBHOOK_MOCK_KNOWN_INBOUND_WAMIDS: defaultInbound.id },
    async (post) => {
      const payload = buildMetaPayload(
        [defaultInbound],
        [{ id: "wamid.FAKE_OUT_1", status: "delivered" }],
      );
      for (let i = 0; i < 2; i += 1) {
        const res = await post(payload);
        if (res.status !== 200) throw new Error(`replay ${i} expected 200, got ${res.status}`);
        const body = await res.json();
        if (body.event !== "mixed") throw new Error(`replay ${i} expected mixed event`);
      }
    },
  );
});

Deno.test("mixed callback returns 503 when status persistence fails", async () => {
  await withWebhook({ WEBHOOK_MOCK_FAIL_STATUS_RPC: "1" }, async (post) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [{ id: "wamid.FAKE_OUT_1", status: "delivered" }],
    ));
    if (res.status !== 503) throw new Error(`expected 503, got ${res.status}`);
    const body = await res.json();
    if (body.error !== "status_persistence_failed") {
      throw new Error(`unexpected error body: ${JSON.stringify(body)}`);
    }
  });
});

Deno.test("mixed callback returns 503 when inbound durable persistence fails", async () => {
  await withWebhook({ WEBHOOK_MOCK_FAIL_INBOUND_INSERT: "1" }, async (post) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [{ id: "wamid.FAKE_OUT_1", status: "delivered" }],
    ));
    if (res.status !== 503) throw new Error(`expected 503, got ${res.status}`);
    const body = await res.json();
    if (body.error !== "durable_persistence_failed") {
      throw new Error(`unexpected error body: ${JSON.stringify(body)}`);
    }
  });
});

Deno.test("mixed callback with unknown status provider id fails closed with 503", async () => {
  await withWebhook({ WEBHOOK_MOCK_MATCHED_PROVIDER_IDS: "" }, async (post) => {
    const res = await post(buildMetaPayload(
      [defaultInbound],
      [{ id: "wamid.FAKE_UNKNOWN_OUT", status: "delivered" }],
    ));
    if (res.status !== 503) throw new Error(`expected 503 for unmatched status, got ${res.status}`);
    const body = await res.json();
    if (body.error !== "status_persistence_failed") {
      throw new Error(`unexpected error: ${JSON.stringify(body)}`);
    }
  });
});

Deno.test("multiple inbound messages in one callback are each processed", async () => {
  await withWebhook({}, async (post) => {
    const res = await post(buildMetaPayload(
      [
        { id: "wamid.FAKE_IN_A", from: "000000000000", body: "first fixture" },
        { id: "wamid.FAKE_IN_B", from: "000000000000", body: "second fixture" },
      ],
      [{ id: "wamid.FAKE_OUT_1", status: "sent" }],
    ));
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.json();
    if (body.event !== "mixed" || body.inbound_processed !== 2) {
      throw new Error(`expected two inbound results: ${JSON.stringify(body)}`);
    }
  });
});
