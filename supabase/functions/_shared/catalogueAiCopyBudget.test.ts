import {
  type Accounting,
  APPROVED_MODEL,
  type BudgetedDeps,
  buildProviderRequests,
  MAX_BODY_BYTES,
  MAX_INPUT_TOKENS,
  MAX_OUTPUT_TOKENS,
  type ProviderReply,
  runBudgetedInference,
  serializedByteLength,
} from "./catalogueAiCopyBudget.ts";
import {
  buildCatalogueCopyPrompt,
  catalogueCopyJsonSchema,
} from "./catalogueAiCopy.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e} got ${a}`);
}

const SYSTEM_PROMPT = "s".repeat(600);
const PRODUCT = {
  productName: "Pistachio Baklava",
  tone: "premium" as const,
};

function requests(userPrompt = buildCatalogueCopyPrompt(PRODUCT)) {
  return buildProviderRequests(
    SYSTEM_PROMPT,
    userPrompt,
    catalogueCopyJsonSchema,
  );
}

const GOOD_COUNT: ProviderReply = {
  status: 200,
  body: { object: "response.input_tokens", input_tokens: 1200 },
  requestId: "req-count",
};
const GOOD_INFERENCE: ProviderReply = {
  status: 200,
  body: {
    model: APPROVED_MODEL,
    service_tier: "default",
    usage: { input_tokens: 1180, output_tokens: 400 },
    output: [],
  },
  requestId: "req-infer",
};

interface Harness {
  calls: string[];
  deps: BudgetedDeps;
  settleArgs: unknown[][];
  reserveArgs: unknown[][];
}

function harness(overrides: {
  gate?: () => Promise<string | null>;
  reserve?: () => Promise<boolean>;
  settle?: () => Promise<{ status?: string; violation?: string | null }>;
  markAmbiguous?: () => Promise<void>;
  emergencyDisable?: () => Promise<void>;
  count?: () => Promise<ProviderReply>;
  infer?: () => Promise<ProviderReply>;
  req?: ReturnType<typeof requests>;
} = {}): Harness {
  const calls: string[] = [];
  const settleArgs: unknown[][] = [];
  const reserveArgs: unknown[][] = [];
  const accounting: Accounting = {
    gate: (..._a) => {
      calls.push("gate");
      return (overrides.gate ?? (() => Promise.resolve("res-1")))();
    },
    reserve: (...a) => {
      calls.push("reserve");
      reserveArgs.push(a);
      return (overrides.reserve ?? (() => Promise.resolve(true)))();
    },
    settle: (...a) => {
      calls.push("settle");
      settleArgs.push(a);
      return (overrides.settle ??
        (() => Promise.resolve({ status: "settled", violation: null })))();
    },
    markAmbiguous: (..._a) => {
      calls.push("markAmbiguous");
      return (overrides.markAmbiguous ?? (() => Promise.resolve()))();
    },
    emergencyDisable: (..._a) => {
      calls.push("emergencyDisable");
      return (overrides.emergencyDisable ?? (() => Promise.resolve()))();
    },
  };
  return {
    calls,
    settleArgs,
    reserveArgs,
    deps: {
      actorId: "actor-1",
      requests: overrides.req ?? requests(),
      accounting,
      countTokens: () => {
        calls.push("count");
        return (overrides.count ?? (() => Promise.resolve(GOOD_COUNT)))();
      },
      infer: () => {
        calls.push("infer");
        return (overrides.infer ?? (() => Promise.resolve(GOOD_INFERENCE)))();
      },
    },
  };
}

Deno.test("happy path runs gate, count, reserve, infer, settle in order, once each", async () => {
  const h = harness();
  const result = await runBudgetedInference(h.deps);
  assert(result.ok, "expected success");
  assertEquals(h.calls, ["gate", "count", "reserve", "infer", "settle"]);
});

Deno.test("reserve receives the gate id, actor, approved model and the OFFICIAL counted tokens", async () => {
  const h = harness();
  await runBudgetedInference(h.deps);
  assertEquals(h.reserveArgs[0], ["res-1", "actor-1", APPROVED_MODEL, 1200]);
});

Deno.test("settlement receives verified provider usage, request id, response model and tier", async () => {
  const h = harness();
  await runBudgetedInference(h.deps);
  assertEquals(h.settleArgs[0], [
    "res-1",
    1180,
    400,
    "req-infer",
    APPROVED_MODEL,
    "default",
  ]);
});

Deno.test("count and inference payloads are the same model, input, schema and reasoning", () => {
  const { countBody, inferenceBody } = requests();
  assertEquals(
    Object.fromEntries(
      Object.entries(inferenceBody).filter(([k]) =>
        k !== "service_tier" && k !== "max_output_tokens"
      ),
    ),
    countBody,
  );
  assertEquals(inferenceBody.model, APPROVED_MODEL);
  assertEquals(inferenceBody.service_tier, "default");
  assertEquals(inferenceBody.max_output_tokens, MAX_OUTPUT_TOKENS);
  assertEquals(
    (inferenceBody.reasoning as { effort: string }).effort,
    "none",
  );
  assert(!("tools" in inferenceBody), "no tools may be configured");
  assert(!("tools" in countBody), "no tools may be configured");
  assert(
    !("max_output_tokens" in countBody) && !("service_tier" in countBody),
    "count carries only what the counting endpoint accepts",
  );
});

Deno.test("worst-case product input stays far below the serialized byte ceiling", () => {
  const input = {
    productName: "ह".repeat(160),
    category: "ह".repeat(100),
    subcategory: "ह".repeat(100),
    packSize: "ह".repeat(80),
    saleTypeLabel: "ह".repeat(80),
    storageInstructions: "ह".repeat(300),
    shelfLifeDays: 3650,
    tone: "premium" as const,
  };
  const bytes = serializedByteLength(
    requests(buildCatalogueCopyPrompt(input)).inferenceBody,
  );
  assert(bytes < MAX_BODY_BYTES, `worst-case body ${bytes} bytes`);
});

Deno.test("a gate denial stops everything: no count, no reserve, no inference", async () => {
  const h = harness({ gate: () => Promise.resolve(null) });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 429);
  assertEquals(h.calls, ["gate"]);
});

Deno.test("gate accounting failure fails closed with zero provider calls", async () => {
  const h = harness({ gate: () => Promise.reject(new Error("db down")) });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 503);
  assertEquals(h.calls, ["gate"]);
});

Deno.test("authenticate-and-rate-limit gate runs before the counting call", async () => {
  const h = harness();
  await runBudgetedInference(h.deps);
  assert(h.calls.indexOf("gate") < h.calls.indexOf("count"));
});

Deno.test("an oversized serialized body is refused before counting or reserving", async () => {
  const h = harness({
    req: requests(buildCatalogueCopyPrompt({
      productName: "x".repeat(MAX_BODY_BYTES + 100),
      tone: "premium",
    })),
  });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 413);
  assertEquals(h.calls, ["gate"]);
});

Deno.test("every counting failure fails closed with no reservation and no inference", async () => {
  const cases: Array<[string, () => Promise<ProviderReply>]> = [
    ["throws", () => Promise.reject(new Error("network"))],
    ["401", () => Promise.resolve({ status: 401, body: {}, requestId: null })],
    ["403", () => Promise.resolve({ status: 403, body: {}, requestId: null })],
    ["429", () => Promise.resolve({ status: 429, body: {}, requestId: null })],
    ["500", () => Promise.resolve({ status: 500, body: {}, requestId: null })],
    [
      "null body",
      () => Promise.resolve({ status: 200, body: null, requestId: null }),
    ],
    [
      "missing count",
      () => Promise.resolve({ status: 200, body: {}, requestId: null }),
    ],
    [
      "zero",
      () =>
        Promise.resolve({
          status: 200,
          body: { input_tokens: 0 },
          requestId: null,
        }),
    ],
    [
      "fractional",
      () =>
        Promise.resolve({
          status: 200,
          body: { input_tokens: 10.5 },
          requestId: null,
        }),
    ],
    [
      "negative",
      () =>
        Promise.resolve({
          status: 200,
          body: { input_tokens: -1 },
          requestId: null,
        }),
    ],
    [
      "string",
      () =>
        Promise.resolve({
          status: 200,
          body: { input_tokens: "12" },
          requestId: null,
        }),
    ],
  ];
  for (const [name, count] of cases) {
    const h = harness({ count });
    const result = await runBudgetedInference(h.deps);
    assert(!result.ok && result.status === 503, `count case ${name}`);
    assertEquals(h.calls, ["gate", "count"], `count case ${name}`);
  }
});

Deno.test("a count above 8,000 is refused; exactly 8,000 is allowed", async () => {
  const over = harness({
    count: () =>
      Promise.resolve({
        status: 200,
        body: { input_tokens: MAX_INPUT_TOKENS + 1 },
        requestId: null,
      }),
  });
  const refused = await runBudgetedInference(over.deps);
  assert(!refused.ok && refused.status === 413);
  assertEquals(over.calls, ["gate", "count"]);

  const exact = harness({
    count: () =>
      Promise.resolve({
        status: 200,
        body: { input_tokens: MAX_INPUT_TOKENS },
        requestId: null,
      }),
  });
  assert((await runBudgetedInference(exact.deps)).ok);
});

Deno.test("a reservation denial or accounting error means zero inference", async () => {
  const denied = harness({ reserve: () => Promise.resolve(false) });
  const a = await runBudgetedInference(denied.deps);
  assert(!a.ok && a.status === 429);
  assertEquals(denied.calls, ["gate", "count", "reserve"]);

  const broken = harness({ reserve: () => Promise.reject(new Error("db")) });
  const b = await runBudgetedInference(broken.deps);
  assert(!b.ok && b.status === 503);
  assertEquals(broken.calls, ["gate", "count", "reserve"]);
});

Deno.test("a non-approved model is refused before any accounting or provider call", async () => {
  const bad = requests();
  bad.inferenceBody.model = "gpt-5.4-mini";
  const h = harness({ req: bad });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 503);
  assertEquals(h.calls, []);
});

Deno.test("ambiguous provider failures keep the reservation and never retry", async () => {
  const cases: Array<[string, () => Promise<ProviderReply>]> = [
    ["throws", () => Promise.reject(new DOMException("aborted", "AbortError"))],
    ["500", () => Promise.resolve({ status: 500, body: {}, requestId: null })],
    ["429", () => Promise.resolve({ status: 429, body: {}, requestId: null })],
    [
      "null body",
      () => Promise.resolve({ status: 200, body: null, requestId: null }),
    ],
    [
      "no usage",
      () =>
        Promise.resolve({
          status: 200,
          body: { output: [], model: APPROVED_MODEL, service_tier: "default" },
          requestId: null,
        }),
    ],
    [
      "bad usage",
      () =>
        Promise.resolve({
          status: 200,
          body: {
            model: APPROVED_MODEL,
            service_tier: "default",
            usage: { input_tokens: "x", output_tokens: 1 },
          },
          requestId: null,
        }),
    ],
  ];
  for (const [name, infer] of cases) {
    const h = harness({ infer });
    const result = await runBudgetedInference(h.deps);
    assert(!result.ok && result.status === 502, `infer case ${name}`);
    assertEquals(
      h.calls,
      ["gate", "count", "reserve", "infer", "markAmbiguous"],
      `infer case ${name}`,
    );
  }
});

Deno.test("a model or tier mismatch with unverifiable usage latches and keeps the reservation", async () => {
  const cases: Array<[string, Record<string, unknown>]> = [
    ["wrong model", { model: "gpt-other", service_tier: "default" }],
    ["wrong tier", { model: APPROVED_MODEL, service_tier: "flex" }],
    ["missing model", { service_tier: "default" }],
    [
      "wrong model with usage above the settle ceiling",
      {
        model: "gpt-other",
        service_tier: "default",
        usage: { input_tokens: 1_000_001, output_tokens: 1 },
      },
    ],
    [
      "wrong tier with output usage above the settle ceiling",
      {
        model: APPROVED_MODEL,
        service_tier: "flex",
        usage: { input_tokens: 1, output_tokens: 1_000_001 },
      },
    ],
  ];
  for (const [name, extra] of cases) {
    const h = harness({
      infer: () =>
        Promise.resolve({ status: 200, body: { ...extra }, requestId: null }),
    });
    const result = await runBudgetedInference(h.deps);
    assert(!result.ok && result.status === 502, name);
    assertEquals(
      h.calls,
      [
        "gate",
        "count",
        "reserve",
        "infer",
        "emergencyDisable",
        "markAmbiguous",
      ],
      name,
    );
  }
});

Deno.test("unverifiable usage with the approved model/tier or a provider error does not latch", async () => {
  const ok = harness({
    infer: () =>
      Promise.resolve({
        status: 200,
        body: { model: APPROVED_MODEL, service_tier: "default" },
        requestId: null,
      }),
  });
  await runBudgetedInference(ok.deps);
  assertEquals(ok.calls, [
    "gate",
    "count",
    "reserve",
    "infer",
    "markAmbiguous",
  ]);
  const err = harness({
    infer: () =>
      Promise.resolve({ status: 429, body: { error: {} }, requestId: null }),
  });
  await runBudgetedInference(err.deps);
  assertEquals(err.calls, [
    "gate",
    "count",
    "reserve",
    "infer",
    "markAmbiguous",
  ]);
});

Deno.test("a failing emergencyDisable is swallowed and the reservation is still marked ambiguous", async () => {
  const h = harness({
    infer: () =>
      Promise.resolve({ status: 200, body: { model: "x" }, requestId: null }),
    emergencyDisable: () => Promise.reject(new Error("db")),
  });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 502);
  assertEquals(h.calls.at(-1), "markAmbiguous");
});

Deno.test("a failing markAmbiguous is swallowed: the reservation simply stays held", async () => {
  const h = harness({
    infer: () => Promise.reject(new Error("timeout")),
    markAmbiguous: () => Promise.reject(new Error("db")),
  });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 502);
});

Deno.test("a settlement accounting failure withholds the content and fails closed", async () => {
  const h = harness({ settle: () => Promise.reject(new Error("db")) });
  const result = await runBudgetedInference(h.deps);
  assert(!result.ok && result.status === 503);
  assertEquals(h.calls, ["gate", "count", "reserve", "infer", "settle"]);
});

Deno.test("a tripwire violation or non-settled outcome withholds the content", async () => {
  const violation = harness({
    settle: () =>
      Promise.resolve({ status: "settled", violation: "model_mismatch" }),
  });
  const a = await runBudgetedInference(violation.deps);
  assert(!a.ok && a.status === 502);

  const ambiguous = harness({
    settle: () => Promise.resolve({ status: "ambiguous" }),
  });
  const b = await runBudgetedInference(ambiguous.deps);
  assert(!b.ok && b.status === 502);
});

Deno.test("inference is never reached without a successful reservation (all stop points)", async () => {
  const stops: Array<Partial<Parameters<typeof harness>[0]>> = [
    { gate: () => Promise.resolve(null) },
    { gate: () => Promise.reject(new Error("x")) },
    { count: () => Promise.reject(new Error("x")) },
    { reserve: () => Promise.resolve(false) },
    { reserve: () => Promise.reject(new Error("x")) },
  ];
  for (const stop of stops) {
    const h = harness(stop);
    await runBudgetedInference(h.deps);
    assert(
      !h.calls.includes("infer"),
      `inference reached with ${JSON.stringify(h.calls)}`,
    );
  }
});

// ---- Static contract on the Edge handler source: the paid fetch is reachable only through the guard.
Deno.test("handler source: one paid inference fetch, only invoked by the budget orchestrator", async () => {
  const source = await Deno.readTextFile(
    new URL("../catalogue-ai-copy/index.ts", import.meta.url),
  );
  const inferenceFetches = source.match(
    /fetch\(\s*"https:\/\/api\.openai\.com\/v1\/responses"/g,
  ) ?? [];
  assertEquals(inferenceFetches.length, 1, "exactly one paid inference fetch");
  const countFetches = source.match(
    /fetch\(\s*"https:\/\/api\.openai\.com\/v1\/responses\/input_tokens"/g,
  ) ?? [];
  assertEquals(countFetches.length, 1, "exactly one counting fetch");
  assertEquals(
    (source.match(/\binfer\(/g) ?? []).length,
    1,
    "infer is declared once and never called directly",
  );
  assert(
    /runBudgetedInference\(\{[\s\S]*?\binfer,/.test(source),
    "infer is passed only to the orchestrator",
  );
  assertEquals(
    (source.match(/redirect: "error"/g) ?? []).length,
    2,
    "both provider calls must refuse redirects (one POST per reservation)",
  );
  assert(
    source.includes("model !== APPROVED_MODEL"),
    "configured model must equal the approved snapshot",
  );
  assert(source.includes("catalogue_ai_copy_budget_gate_v1"));
  assert(source.includes("catalogue_ai_copy_budget_reserve_v1"));
  assert(source.includes("catalogue_ai_copy_budget_settle_v1"));
  assert(
    source.includes("SUPABASE_SERVICE_ROLE_KEY"),
    "accounting uses the server-only key",
  );
  assert(
    !/retry|fallback|setTimeout\([^)]*fetch/i.test(
      source.replace(/\/\/.*$/gm, ""),
    ),
    "no retry or fallback logic",
  );
});
