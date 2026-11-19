function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`${message || "values differ"}: expected ${e}, got ${a}`);
  }
}
import {
  handleGiftingEnquiryRequest,
  MAX_BODY_BYTES,
  type ReceiveFn,
  type ReceiveResult,
} from "./giftingEnquiryReceiver.ts";

const LEAD = "6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6e";
const TOKEN = "oc_staging_" + "a".repeat(48);
const PAYLOAD = {
  kind: "corporate",
  email: "buyer@example.test",
  phone: null,
  name: "Test Buyer",
  company: null,
  message: "200 boxes",
  source: "business-page",
  consent: { marketing: false, timestamp: null },
  attribution: {},
};

function request(init: {
  method?: string;
  headers?: Record<string, string | undefined>;
  body?: string;
} = {}): Request {
  const headers: Record<string, string> = {
    authorization: `Bearer ${TOKEN}`,
    "idempotency-key": LEAD,
    "content-type": "application/json",
  };
  for (const [k, v] of Object.entries(init.headers ?? {})) {
    if (v === undefined) delete headers[k];
    else headers[k] = v;
  }
  return new Request(
    "https://core.example.test/functions/v1/gifting-enquiries",
    {
      method: init.method ?? "POST",
      headers,
      body: init.method === "GET"
        ? undefined
        : (init.body ?? JSON.stringify(PAYLOAD)),
    },
  );
}

function stub(result: ReceiveResult | Error) {
  const calls: Array<
    { token: string; lead: string; payload: Record<string, unknown> }
  > = [];
  const fn: ReceiveFn = (token, lead, payload) => {
    calls.push({ token, lead, payload });
    return result instanceof Error
      ? Promise.reject(result)
      : Promise.resolve(result);
  };
  return { fn, calls };
}

const accepted = (replayed: boolean): ReceiveResult => ({
  data: {
    status: "accepted",
    queue: "gifting_enquiries",
    sourceLeadId: LEAD,
    enquiryId: "11111111-2222-3333-4444-555555555555",
    replayed,
  },
  error: null,
});

Deno.test("first delivery returns 201 with the receipt the website client verifies", async () => {
  const { fn, calls } = stub(accepted(false));
  const res = await handleGiftingEnquiryRequest(request(), fn);
  assertEquals(res.status, 201);
  assertEquals(res.headers.get("content-type"), "application/json");
  assertEquals(res.headers.get("cache-control"), "no-store");
  const receipt = await res.json();
  // Same checks as the Gifting website's sendGiftingEnquiry (PR #37).
  assertEquals(receipt.status, "accepted");
  assertEquals(receipt.queue, "gifting_enquiries");
  assertEquals(receipt.sourceLeadId, LEAD);
  assert(
    typeof receipt.enquiryId === "string" && receipt.enquiryId.trim() !== "",
  );
  assertEquals(calls.length, 1);
  assertEquals(calls[0]!.token, TOKEN);
  assertEquals(calls[0]!.lead, LEAD);
  assertEquals(calls[0]!.payload.kind, "corporate");
});

Deno.test("an exact replay returns 200 with the same enquiry id", async () => {
  const { fn } = stub(accepted(true));
  const res = await handleGiftingEnquiryRequest(request(), fn);
  assertEquals(res.status, 200);
  const receipt = await res.json();
  assertEquals(receipt.enquiryId, "11111111-2222-3333-4444-555555555555");
  assertEquals(receipt.replayed, true);
});

Deno.test("idempotency key is normalised to lower case before it reaches the database", async () => {
  const { fn, calls } = stub(accepted(false));
  await handleGiftingEnquiryRequest(
    request({ headers: { "idempotency-key": LEAD.toUpperCase() } }),
    fn,
  );
  assertEquals(calls[0]!.lead, LEAD);
});

Deno.test("a conflicting payload maps to 409 and leaks no detail", async () => {
  const { fn } = stub({
    data: null,
    error: { message: "GIFTING_ENQUIRY_PAYLOAD_CONFLICT", code: "P0001" },
  });
  const res = await handleGiftingEnquiryRequest(request(), fn);
  assertEquals(res.status, 409);
  assertEquals(await res.json(), { error: "payload_conflict" });
});

Deno.test("authentication failures map to 401 and scope failures to 403", async () => {
  for (
    const message of ["CONNECT_TOKEN_INVALID", "CONNECT_AUTHORIZATION_DENIED"]
  ) {
    const res = await handleGiftingEnquiryRequest(
      request(),
      stub({ data: null, error: { message } }).fn,
    );
    assertEquals(res.status, 401);
    assert(res.headers.get("www-authenticate")?.startsWith("Bearer"));
    await res.body?.cancel();
  }
  const res = await handleGiftingEnquiryRequest(
    request(),
    stub({ data: null, error: { message: "CONNECT_SCOPE_DENIED" } }).fn,
  );
  assertEquals(res.status, 403);
  await res.body?.cancel();
});

Deno.test("a missing or malformed bearer token is rejected before the database is called", async () => {
  for (
    const authorization of [undefined, "", "Basic abc", "Bearer", "Bearer a b"]
  ) {
    const { fn, calls } = stub(accepted(false));
    const res = await handleGiftingEnquiryRequest(
      request({ headers: { authorization } }),
      fn,
    );
    assertEquals(res.status, 401);
    assertEquals(calls.length, 0);
    await res.body?.cancel();
  }
});

Deno.test("a missing or non-UUID idempotency key is rejected with 400", async () => {
  for (const key of [undefined, "", "not-a-uuid", LEAD + "x"]) {
    const { fn, calls } = stub(accepted(false));
    const res = await handleGiftingEnquiryRequest(
      request({ headers: { "idempotency-key": key } }),
      fn,
    );
    assertEquals(res.status, 400);
    assertEquals(calls.length, 0);
    await res.body?.cancel();
  }
});

Deno.test("only POST with a JSON body is accepted", async () => {
  const get = await handleGiftingEnquiryRequest(
    request({ method: "GET" }),
    stub(accepted(false)).fn,
  );
  assertEquals(get.status, 405);
  assertEquals(get.headers.get("allow"), "POST");
  await get.body?.cancel();

  const wrongType = await handleGiftingEnquiryRequest(
    request({ headers: { "content-type": "text/plain" } }),
    stub(accepted(false)).fn,
  );
  assertEquals(wrongType.status, 415);
  await wrongType.body?.cancel();

  for (const body of ["{not json", "[]", "null", '"text"']) {
    const { fn, calls } = stub(accepted(false));
    const res = await handleGiftingEnquiryRequest(request({ body }), fn);
    assert(
      res.status === 400 || res.status === 422,
      `status ${res.status} for ${body}`,
    );
    assertEquals(calls.length, 0);
    await res.body?.cancel();
  }
});

Deno.test("oversized bodies are rejected before the database is called", async () => {
  const { fn, calls } = stub(accepted(false));
  const big = JSON.stringify({
    ...PAYLOAD,
    message: "m".repeat(MAX_BODY_BYTES),
  });
  const res = await handleGiftingEnquiryRequest(request({ body: big }), fn);
  assertEquals(res.status, 413);
  assertEquals(calls.length, 0);
  await res.body?.cancel();
});

Deno.test("database validation failures map to 422", async () => {
  const res = await handleGiftingEnquiryRequest(
    request(),
    stub({
      data: null,
      error: { message: "GIFTING_ENQUIRY_INVALID", code: "22023" },
    }).fn,
  );
  assertEquals(res.status, 422);
  await res.body?.cancel();
});

Deno.test("infrastructure faults are retryable 503s, never a false acceptance", async () => {
  const cases: Array<ReceiveResult | Error> = [
    { data: null, error: { message: "connection refused", code: "08006" } },
    new Error("network down"),
    { data: { status: "accepted" }, error: null }, // incomplete receipt
    { data: null, error: null },
  ];
  for (const c of cases) {
    const res = await handleGiftingEnquiryRequest(request(), stub(c).fn);
    assertEquals(res.status, 503);
    assertEquals(res.headers.get("retry-after"), "30");
    const text = await res.text();
    assert(!text.includes("connection refused") && !text.includes(TOKEN));
  }
});

Deno.test("streamed overflow cancels early without Content-Length or database calls", async () => {
  for (const declared of [undefined, "1"]) {
    let pulls = 0;
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls++;
        controller.enqueue(new Uint8Array(1024));
        if (pulls === 64) controller.close();
      },
      cancel() {
        cancelled = true;
      },
    }, { highWaterMark: 0 });
    const headers = new Headers(request().headers);
    if (declared) headers.set("content-length", declared);
    const req = new Request("https://core.example.test", {
      method: "POST",
      headers,
      body: stream,
    });
    const { fn, calls } = stub(accepted(false));
    const response = await handleGiftingEnquiryRequest(req, fn);
    assertEquals(response.status, 413);
    assert(cancelled, "source must be cancelled on overflow");
    assertEquals(
      pulls,
      MAX_BODY_BYTES / 1024 + 1,
      "stop at the first overflowing chunk",
    );
    assertEquals(calls.length, 0);
  }
});

Deno.test("declared oversized bodies are refused without reading the stream", async () => {
  let pulls = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulls++;
      controller.close();
    },
  }, { highWaterMark: 0 });
  const headers = new Headers(request().headers);
  headers.set("content-length", String(MAX_BODY_BYTES + 1));
  const req = new Request("https://core.example.test", {
    method: "POST",
    headers,
    body: stream,
  });
  const { fn, calls } = stub(accepted(false));
  const response = await handleGiftingEnquiryRequest(req, fn);
  assertEquals(response.status, 413);
  assertEquals(pulls, 0);
  assertEquals(calls.length, 0);
  await req.body?.cancel();
});

Deno.test("UTF-8 split between chunks is decoded after bounded reading", async () => {
  const bytes = new TextEncoder().encode(
    JSON.stringify({ ...PAYLOAD, name: "é😀" }),
  );
  let index = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index === bytes.length) controller.close();
      else controller.enqueue(bytes.slice(index, ++index));
    },
  }, { highWaterMark: 0 });
  const req = new Request("https://core.example.test", {
    method: "POST",
    headers: request().headers,
    body: stream,
  });
  const { fn, calls } = stub(accepted(false));
  assertEquals((await handleGiftingEnquiryRequest(req, fn)).status, 201);
  assertEquals(calls[0]!.payload.name, "é😀");
});

Deno.test("a body exactly at the byte limit remains accepted", async () => {
  const body = JSON.stringify({ x: "a".repeat(MAX_BODY_BYTES - 8) });
  assertEquals(new TextEncoder().encode(body).length, MAX_BODY_BYTES);
  const { fn, calls } = stub(accepted(false));
  assertEquals(
    (await handleGiftingEnquiryRequest(request({ body }), fn)).status,
    201,
  );
  assertEquals(calls.length, 1);
});
