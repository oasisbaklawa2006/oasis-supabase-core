import { extractOrderQuantity } from "./parseOrderQuantity.ts";

Deno.test("quantity extractor preserves a missing quantity as unresolved", () => {
  if (extractOrderQuantity("pista bulbul") !== null) {
    throw new Error("missing quantity must remain unresolved");
  }
});

Deno.test("quantity extractor preserves an explicit quantity", () => {
  if (extractOrderQuantity("12 cartons pista bulbul") !== 12) {
    throw new Error("explicit quantity must be preserved");
  }
});
