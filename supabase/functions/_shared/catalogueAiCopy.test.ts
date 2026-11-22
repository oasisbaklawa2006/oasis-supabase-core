import {
  buildCatalogueCopyPrompt,
  buildGovernedCatalogueCopyResponse,
  canGenerateStudioAiCopy,
  CATALOGUE_COPY_CHANNEL_PROMPT_VERSION,
  CATALOGUE_COPY_FIELDS,
  CATALOGUE_COPY_PROMPT_VERSION,
  CATALOGUE_COPY_SOURCE_VERSION,
  extractResponsesText,
  parseCatalogueCopyRequest,
  resolveSupabasePublicKey,
  validateCatalogueCopy,
} from "./catalogueAiCopy.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrows(fn: () => unknown, pattern: RegExp) {
  try {
    fn();
  } catch (error) {
    assert(
      error instanceof Error && pattern.test(error.message),
      `unexpected error: ${String(error)}`,
    );
    return;
  }
  throw new Error("expected function to throw");
}

Deno.test("normalizes and bounds catalogue-copy input", () => {
  const parsed = parseCatalogueCopyRequest({
    productName: "  Date   Truffles ",
    shelfLifeDays: 180,
  });
  assert(parsed.productName === "Date Truffles");
  assert(parsed.tone === "premium");
  assert(/"shelfLifeDays":180/.test(buildCatalogueCopyPrompt(parsed)));
  assert(/only as product data/.test(buildCatalogueCopyPrompt(parsed)));
});

Deno.test("rejects missing product names and invented shelf-life ranges", () => {
  assertThrows(
    () => parseCatalogueCopyRequest({ productName: " " }),
    /required/,
  );
  assertThrows(
    () => parseCatalogueCopyRequest({ productName: "Dates", shelfLifeDays: 0 }),
    /shelfLifeDays/,
  );
});

Deno.test("requires exactly the governed output fields", () => {
  const output = Object.fromEntries(
    CATALOGUE_COPY_FIELDS.map((field) => [field, `${field} copy`]),
  );
  assert(
    JSON.stringify(validateCatalogueCopy(output)) === JSON.stringify(output),
  );
  assertThrows(
    () => validateCatalogueCopy({ ...output, price: "100" }),
    /unexpected/,
  );
});

Deno.test("extracts structured Responses API output text", () => {
  assert(
    extractResponsesText({
      output: [{ content: [{ type: "output_text", text: "{}" }] }],
    }) === "{}",
  );
  assertThrows(() => extractResponsesText({ output: [] }), /no output text/);
});

Deno.test("prefers the modern publishable key and supports the legacy fallback", () => {
  const modern = new Map([
    [
      "SUPABASE_PUBLISHABLE_KEYS",
      JSON.stringify({ default: "SB_DEFAULT_KEY" }),
    ],
    ["SB_DEFAULT_KEY", "sb_publishable_test"],
    ["SUPABASE_ANON_KEY", "legacy-anon"],
  ]);
  assert(
    resolveSupabasePublicKey((name) => modern.get(name)) ===
      "sb_publishable_test",
  );
  assert(
    resolveSupabasePublicKey((name) =>
      name === "SUPABASE_ANON_KEY" ? "legacy-anon" : undefined
    ) ===
      "legacy-anon",
  );
});

Deno.test("AI copy requires positive Studio-specific ai.use permission", async () => {
  const allow = await canGenerateStudioAiCopy(() =>
    Promise.resolve({
      data: true,
      error: null,
    })
  );
  assert(allow === true);
  for (const denied of [false, null, "true"]) {
    const result = await canGenerateStudioAiCopy(() =>
      Promise.resolve({
        data: denied,
        error: null,
      })
    );
    assert(result === false);
  }
  assert(
    (await canGenerateStudioAiCopy(() =>
      Promise.resolve({
        data: true,
        error: { message: "denied" },
      })
    )) === false,
  );
  assert(
    (await canGenerateStudioAiCopy(() =>
      Promise.reject(new Error("network failure"))
    )) === false,
  );
});

Deno.test("Studio success envelope preserves human-review and version provenance", () => {
  const content = Object.fromEntries(
    CATALOGUE_COPY_FIELDS.map((key) => [key, key + " suggestion"]),
  ) as Record<(typeof CATALOGUE_COPY_FIELDS)[number], string>;
  const result = buildGovernedCatalogueCopyResponse(content, {
    providerRequestId: "qa-request-id",
    model: "test-model",
    generatedAt: "2026-11-23T00:00:00.000Z",
  });
  assert(result.ok === true && result.content === content);
  assert(
    result.human_review_required === true && result.suggestion_only === true,
  );
  assert(result.approved === false);
  assert(
    result.source_version === "point48-v1" &&
      CATALOGUE_COPY_SOURCE_VERSION === "point48-v1",
  );
  assert(
    result.channel_prompt_version === "point50-v1" &&
      CATALOGUE_COPY_CHANNEL_PROMPT_VERSION === "point50-v1",
  );
  assert(
    result.prompt_version === "catalogue-ai-copy-v1" &&
      CATALOGUE_COPY_PROMPT_VERSION === "catalogue-ai-copy-v1",
  );
  assert(
    result.provider_request_id === "qa-request-id" &&
      result.model === "test-model",
  );
  assert(result.provider === "openai");
  assert(result.generated_at === "2026-11-23T00:00:00.000Z");
  assertThrows(
    () =>
      buildGovernedCatalogueCopyResponse({ ...content, price: "100" }, {
        providerRequestId: null,
        model: "test-model",
        generatedAt: "2026-11-23T00:00:00.000Z",
      }),
    /unexpected model output fields/,
  );
});
