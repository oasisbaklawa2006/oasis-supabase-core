import {
  audioFileExtension,
  base64ToBytes,
  genieOrderJsonSchema,
  parseGenieOrderRequest,
  validateGenieOrderOutput,
} from "./genieOrderParse.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrows(fn: () => unknown, pattern: RegExp) {
  try {
    fn();
  } catch (error) {
    assert(error instanceof Error && pattern.test(error.message), String(error));
    return;
  }
  throw new Error("expected function to throw");
}

Deno.test("accepts governed text input and defaults locale", () => {
  const parsed = parseGenieOrderRequest({ mode: "text", text: "20 box baklawa" });
  assert(parsed.mode === "text");
  assert(parsed.text === "20 box baklawa");
  assert(parsed.locale === "en-IN");
});

Deno.test("requires explicit input for every mode", () => {
  assertThrows(() => parseGenieOrderRequest({ mode: "text", text: " " }), /text is required/);
  assertThrows(() => parseGenieOrderRequest({ mode: "image" }), /file content/);
  assertThrows(
    () => parseGenieOrderRequest({ mode: "image", mime_type: "image/svg+xml", content_base64: "YWJj" }),
    /unsupported/,
  );
});

Deno.test("accepts image, document and audio file contracts", () => {
  for (const fixture of [
    { mode: "image", mime_type: "image/jpeg" },
    { mode: "document", mime_type: "application/pdf" },
    { mode: "audio", mime_type: "audio/mpeg" },
  ]) {
    const parsed = parseGenieOrderRequest({ ...fixture, content_base64: "YWJjZA==" });
    assert(parsed.mode === fixture.mode);
  }
});

Deno.test("rejects malformed base64 and oversized/unknown model lines", () => {
  assertThrows(
    () => parseGenieOrderRequest({ mode: "audio", mime_type: "audio/mpeg", content_base64: "***" }),
    /base64/,
  );
  assertThrows(
    () => validateGenieOrderOutput({ lines: [{ productName: "", quantity: 2, uom: "box" }] }),
    /product name/,
  );
  assertThrows(
    () => validateGenieOrderOutput({ lines: [{ productName: "Baklawa", quantity: 0, uom: "box" }] }),
    /quantity/,
  );
});

Deno.test("validates only governed parser output fields", () => {
  const lines = validateGenieOrderOutput({
    lines: [{ productName: "Pistachio Baklawa", quantity: 20, uom: "box" }],
  });
  assert(lines.length === 1 && lines[0].quantity === 20);
  assertThrows(() => validateGenieOrderOutput({ lines, sku: "INVENTED" }), /unexpected/);
  assert(genieOrderJsonSchema.properties.lines.maxItems === 100);
});

Deno.test("decodes binary input and maps audio extensions deterministically", () => {
  const bytes = base64ToBytes("YWJj");
  assert(new TextDecoder().decode(bytes) === "abc");
  assert(audioFileExtension("audio/wav") === "wav");
  assert(audioFileExtension("audio/x-m4a") === "m4a");
  assert(audioFileExtension("audio/mpeg") === "mp3");
});
