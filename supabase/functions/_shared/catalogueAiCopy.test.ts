import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCatalogueCopyPrompt,
  CATALOGUE_COPY_FIELDS,
  extractResponsesText,
  parseCatalogueCopyRequest,
  validateCatalogueCopy,
} from "./catalogueAiCopy.ts";

test("normalizes and bounds catalogue-copy input", () => {
  const parsed = parseCatalogueCopyRequest({ productName: "  Date   Truffles ", shelfLifeDays: 180 });
  assert.equal(parsed.productName, "Date Truffles");
  assert.equal(parsed.tone, "premium");
  assert.match(buildCatalogueCopyPrompt(parsed), /Shelf life: 180 days/);
});

test("rejects missing product names and invented shelf-life ranges", () => {
  assert.throws(() => parseCatalogueCopyRequest({ productName: " " }), /required/);
  assert.throws(() => parseCatalogueCopyRequest({ productName: "Dates", shelfLifeDays: 0 }), /shelfLifeDays/);
});

test("requires exactly the governed output fields", () => {
  const output = Object.fromEntries(CATALOGUE_COPY_FIELDS.map((field) => [field, `${field} copy`]));
  assert.deepEqual(validateCatalogueCopy(output), output);
  assert.throws(() => validateCatalogueCopy({ ...output, price: "100" }), /unexpected/);
});

test("extracts structured Responses API output text", () => {
  assert.equal(extractResponsesText({ output: [{ content: [{ type: "output_text", text: "{}" }] }] }), "{}");
  assert.throws(() => extractResponsesText({ output: [] }), /no output text/);
});
