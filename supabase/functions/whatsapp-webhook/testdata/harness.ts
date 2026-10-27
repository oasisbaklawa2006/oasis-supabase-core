/**
 * Shared black-box harness for whatsapp-webhook tests.
 * Runs the real entrypoint in a subprocess with a stubbed `serve` and an in-process
 * Supabase mock (see supabase-mock.ts). No secrets, localhost only.
 */

export const VERIFY_TOKEN = "unit-test-verify-token-not-production";
const ENTRYPOINT = new URL("../index.ts", import.meta.url);
const IMPORT_MAP = new URL("./import-map.json", import.meta.url);

export type MetaMessage = {
  id: string;
  from: string;
  body: string;
  /** Extra Meta message fields, e.g. `{ type: "image", image: { link, mime_type } }`. */
  extra?: Record<string, unknown>;
};
export type MetaStatus = { id: string; status: string };

export function buildMetaPayload(messages: MetaMessage[], statuses: MetaStatus[]) {
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
            ...(m.extra ?? {}),
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

export function readStats(path: string): Record<string, number> {
  try {
    return JSON.parse(Deno.readTextFileSync(path));
  } catch {
    return {};
  }
}

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
}

export async function withWebhook(
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
    if (!ready) {
      throw new Error("webhook subprocess did not start (OPTIONS probe never returned 204)");
    }

    await run({
      statsPath,
      post: async (body) => {
        const res = await fetch(base, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        });
        // Buffer the body so callers cannot leak an unconsumed response stream.
        const text = await res.text();
        return new Response(text, { status: res.status, headers: res.headers });
      },
    });
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      // already exited
    }
    await child.status;
    try {
      await child.stderr.cancel();
    } catch {
      // already closed
    }
    try {
      await Deno.remove(statsPath);
    } catch {
      // ignore
    }
  }
}

/** Tiny localhost media server so media-download paths run without any external network. */
export async function withMediaServer(
  run: (ctx: { url: string; hits: () => number }) => Promise<void>,
) {
  let count = 0;
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, () => {
    count += 1;
    return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), {
      status: 200,
      headers: { "content-type": "image/png" },
    });
  });
  try {
    const port = (server.addr as Deno.NetAddr).port;
    await run({ url: `http://127.0.0.1:${port}/fixture.png`, hits: () => count });
  } finally {
    await server.shutdown();
  }
}
