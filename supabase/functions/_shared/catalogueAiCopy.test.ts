import {
  buildCatalogueCopyPrompt,
  CATALOGUE_COPY_FIELDS,
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
