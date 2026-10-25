import { boundedMaxJobs } from "./index.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (actual !== expected) {
    throw new Error(
      `${message}: expected=${String(expected)} actual=${String(actual)}`,
    );
  }
}

function assertJsonEquals(actual: unknown, expected: unknown, message: string) {
  assertEquals(JSON.stringify(actual), JSON.stringify(expected), message);
}

Deno.test("consumer defaults to a bounded three-job tick", () => {
  assertEquals(boundedMaxJobs(undefined), 3, "missing max_jobs defaults");
  assertEquals(boundedMaxJobs("5"), 3, "non-numeric max_jobs defaults");
  assertEquals(boundedMaxJobs(2.5), 3, "non-integer max_jobs defaults");
});

Deno.test("consumer clamps requested work to one through five jobs", () => {
  assertEquals(boundedMaxJobs(-10), 1, "negative value clamps to one");
  assertEquals(boundedMaxJobs(0), 1, "zero clamps to one");
  assertEquals(boundedMaxJobs(1), 1, "one is accepted");
  assertEquals(boundedMaxJobs(4), 4, "in-range request is accepted");
  assertEquals(boundedMaxJobs(5), 5, "upper bound is accepted");
  assertEquals(boundedMaxJobs(99), 5, "large request clamps to five");
});

// ---------------------------------------------------------------------------
// Black-box HTTP contract. The real index.ts runs as a subprocess against a
// stub PostgREST, so authentication, the idle path and the malformed-lease path
// are exercised through the same handler that production serves. Only the
// transport `serve` is replaced (testdata/serve-stub.ts).
// ---------------------------------------------------------------------------

const GOOD_SECRET = "unit-test-secret-not-a-real-credential";
const ENTRYPOINT = new URL("./index.ts", import.meta.url);
const IMPORT_MAP = new URL("./testdata/import-map.json", import.meta.url);

type RpcReply = { status: number; body: unknown };
type StubState = {
  secretValid: boolean;
  verifyReply: RpcReply | null;
  claimReply: RpcReply;
  requests: string[];
};

const ALL_NULL_CLAIM_ROW = {
  id: null,
  packet_id: null,
  packet_revision: null,
  lease_token: null,
  execution_kind: null,
  case_id: null,
  context_revision: null,
};

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
}

function json(reply: RpcReply): Response {
  return new Response(JSON.stringify(reply.body), {
    status: reply.status,
    headers: { "content-type": "application/json" },
  });
}

async function withConsumer(
  setup: Partial<StubState>,
  env: Record<string, string>,
  run: (
    call: (init: RequestInit) => Promise<Response>,
    s: StubState,
  ) => Promise<void>,
) {
  const state: StubState = {
    secretValid: true,
    verifyReply: null,
    claimReply: { status: 200, body: ALL_NULL_CLAIM_ROW },
    requests: [],
    ...setup,
  };
  const stubPort = freePort();
  const stub = Deno.serve(
    { port: stubPort, hostname: "127.0.0.1", onListen() {} },
    async (req) => {
      const path = new URL(req.url).pathname;
      state.requests.push(`${req.method} ${path}`);
      const rpc = path.replace("/rest/v1/rpc/", "");
      if (rpc === "verify_whatsapp_packet_ai_consumer_secret") {
        if (state.verifyReply) return json(state.verifyReply);
        const args = await req.json() as { _candidate?: string };
        return json({
          status: 200,
          body: state.secretValid && args._candidate === GOOD_SECRET,
        });
      }
      if (rpc === "claim_whatsapp_packet_ai_dispatch_job") {
        await req.arrayBuffer();
        return json(state.claimReply);
      }
      await req.arrayBuffer();
      return json({ status: 404, body: { message: "unexpected call" } });
    },
  );

  const consumerPort = freePort();
  const child = new Deno.Command(Deno.execPath(), {
    args: [
      "run",
      "--quiet",
      "--allow-net",
      "--allow-env",
      "--allow-read",
      `--import-map=${IMPORT_MAP.pathname}`,
      ENTRYPOINT.pathname,
    ],
    env: {
      CONSUMER_TEST_PORT: String(consumerPort),
      SUPABASE_URL: `http://127.0.0.1:${stubPort}`,
      ...env,
    },
    stdout: "null",
    stderr: "null",
  }).spawn();

  const base = `http://127.0.0.1:${consumerPort}/`;
  try {
    let ready = false;
    for (let attempt = 0; attempt < 100 && !ready; attempt += 1) {
      try {
        const probe = await fetch(base, { method: "GET" });
        await probe.arrayBuffer();
        ready = probe.status === 405;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    if (!ready) throw new Error("consumer subprocess did not start");
    state.requests.length = 0;
    await run((init) => fetch(base, init), state);
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      // already exited
    }
    await child.status;
    await stub.shutdown();
  }
}

const SERVICE_ENV = { SUPABASE_SERVICE_ROLE_KEY: "unit-test-service-role" };

function post(secret: string | null, body: unknown = { max_jobs: 3 }) {
  const headers: Record<string, string> = {
    "content-type": "application/json",
  };
  if (secret !== null) headers["x-oasis-worker-secret"] = secret;
  return { method: "POST", headers, body: JSON.stringify(body) };
}

const claimCalls = (s: StubState) =>
  s.requests.filter((r) => r.endsWith("/claim_whatsapp_packet_ai_dispatch_job"))
    .length;

Deno.test("consumer rejects non-POST before touching the database", async () => {
  await withConsumer({}, SERVICE_ENV, async (call, s) => {
    const res = await call({ method: "GET" });
    assertEquals(res.status, 405, "GET is refused");
    await res.arrayBuffer();
    assertEquals(s.requests.length, 0, "no database request on GET");
  });
});

Deno.test("consumer fails closed with 503 when service credentials are absent", async () => {
  await withConsumer({}, { SUPABASE_SERVICE_ROLE_KEY: "" }, async (call, s) => {
    const res = await call(post(GOOD_SECRET));
    assertEquals(res.status, 503, "unconfigured consumer");
    const body = await res.json();
    assertEquals(body.error, "CONSUMER_NOT_CONFIGURED", "error code");
    assertEquals(s.requests.length, 0, "no database request when unconfigured");
  });
});

Deno.test("consumer returns 401 for a missing or blank worker secret and claims nothing", async () => {
  await withConsumer({}, SERVICE_ENV, async (call, s) => {
    for (const secret of [null, "", "   "]) {
      const res = await call(post(secret));
      assertEquals(res.status, 401, `secret=${JSON.stringify(secret)}`);
      const body = await res.json();
      assertEquals(body.error, "unauthorized", "error code");
    }
    assertEquals(
      s.requests.length,
      0,
      "no verify or claim call without a secret",
    );
  });
});

Deno.test("consumer returns 403 for a wrong worker secret and claims nothing", async () => {
  await withConsumer({}, SERVICE_ENV, async (call, s) => {
    const res = await call(post("wrong-secret"));
    assertEquals(res.status, 403, "wrong secret");
    const text = await res.text();
    assertEquals(JSON.parse(text).error, "forbidden", "error code");
    assertEquals(
      text.includes("wrong-secret"),
      false,
      "secret is never echoed",
    );
    assertEquals(claimCalls(s), 0, "no claim after failed authority");
  });
});

Deno.test("consumer returns 500 and claims nothing when the authority lookup fails", async () => {
  await withConsumer(
    { verifyReply: { status: 500, body: { message: "boom" } } },
    SERVICE_ENV,
    async (call, s) => {
      const res = await call(post(GOOD_SECRET));
      assertEquals(res.status, 500, "authority unavailable");
      const body = await res.json();
      assertEquals(body.error, "authority_unavailable", "error code");
      assertEquals(claimCalls(s), 0, "no claim without verified authority");
    },
  );
});

Deno.test("idle queue (all-NULL claim row) is HTTP 200 idle=true with zero work", async () => {
  await withConsumer({}, SERVICE_ENV, async (call, s) => {
    const res = await call(post(GOOD_SECRET));
    assertEquals(res.status, 200, "idle tick is healthy");
    const text = await res.text();
    assertJsonEquals(
      JSON.parse(text),
      { success: true, idle: true, processed: 0, failed: 0, errors: [] },
      "idle body",
    );
    assertEquals(text.includes(GOOD_SECRET), false, "secret is never echoed");
    assertEquals(claimCalls(s), 1, "one claim, then stop at the first idle");
    assertJsonEquals(
      s.requests,
      [
        "POST /rest/v1/rpc/verify_whatsapp_packet_ai_consumer_secret",
        "POST /rest/v1/rpc/claim_whatsapp_packet_ai_dispatch_job",
      ],
      "idle tick performs only the verify and claim reads",
    );
  });
});

Deno.test("a null claim result is also idle", async () => {
  await withConsumer(
    { claimReply: { status: 200, body: null } },
    SERVICE_ENV,
    async (call) => {
      const res = await call(post(GOOD_SECRET));
      assertEquals(res.status, 200, "null claim is idle");
      const body = await res.json();
      assertEquals(body.idle, true, "idle flag");
      assertEquals(body.processed, 0, "nothing processed");
    },
  );
});

Deno.test("a partially populated claim row fails closed with 502 and mutates nothing", async () => {
  const partials = [
    { ...ALL_NULL_CLAIM_ROW, id: "11111111-1111-4111-8111-111111111111" },
    {
      ...ALL_NULL_CLAIM_ROW,
      id: "11111111-1111-4111-8111-111111111111",
      packet_id: "22222222-2222-4222-8222-222222222222",
      lease_token: "33333333-3333-4333-8333-333333333333",
      packet_revision: 1,
      execution_kind: "UNKNOWN_KIND",
    },
    {
      ...ALL_NULL_CLAIM_ROW,
      id: "11111111-1111-4111-8111-111111111111",
      packet_id: "22222222-2222-4222-8222-222222222222",
      lease_token: "33333333-3333-4333-8333-333333333333",
      packet_revision: 1,
      execution_kind: "CASE_CONTEXT",
    },
  ];
  for (const claim of partials) {
    await withConsumer(
      { claimReply: { status: 200, body: claim } },
      SERVICE_ENV,
      async (call, s) => {
        const res = await call(post(GOOD_SECRET, { max_jobs: 3 }));
        assertEquals(res.status, 502, "malformed lease is not healthy");
        const body = await res.json();
        assertEquals(body.success, false, "success flag");
        assertEquals(body.idle, false, "never reported idle");
        assertEquals(body.processed, 0, "no job processed");
        assertEquals(body.failed, 3, "every attempt failed closed");
        assertJsonEquals(
          body.errors,
          [
            "DISPATCH_CLAIM_INVALID",
            "DISPATCH_CLAIM_INVALID",
            "DISPATCH_CLAIM_INVALID",
          ],
          "error codes",
        );
        const writes = s.requests.filter((r) =>
          !r.endsWith("/verify_whatsapp_packet_ai_consumer_secret") &&
          !r.endsWith("/claim_whatsapp_packet_ai_dispatch_job")
        );
        assertEquals(writes.length, 0, "no completion, retry or table write");
      },
    );
  }
});

Deno.test("a failing claim RPC is reported, not hidden as idle, and stays bounded", async () => {
  await withConsumer(
    { claimReply: { status: 500, body: { message: "claim exploded" } } },
    SERVICE_ENV,
    async (call, s) => {
      const res = await call(post(GOOD_SECRET, { max_jobs: 99 }));
      assertEquals(res.status, 502, "claim failure is unhealthy");
      const body = await res.json();
      assertEquals(body.idle, false, "never idle on error");
      assertEquals(body.processed, 0, "nothing processed");
      assertEquals(claimCalls(s), 5, "max_jobs is clamped to five");
    },
  );
});
