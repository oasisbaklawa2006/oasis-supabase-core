import { extractOrderQuantity } from "./parseOrderQuantity.ts";
import { resolveProductUtterance } from "./resolveProductUtterance.ts";
import type { RuntimeCatalog } from "./types.ts";

const emptyCatalog: RuntimeCatalog = { products: [], aliases: [] };

Deno.test("resolveProductUtterance preserves null order_quantity without defaulting to one", () => {
  const resolution = resolveProductUtterance("pista bulbul", emptyCatalog);
  if (resolution.order_quantity !== null) {
    throw new Error("missing quantity must remain null, never default to one");
  }
});

Deno.test("resolveProductUtterance preserves explicit order_quantity", () => {
  const resolution = resolveProductUtterance("12 cartons pista bulbul", emptyCatalog);
  if (resolution.order_quantity !== 12) {
    throw new Error("explicit quantity must be preserved");
  }
});

Deno.test("extractOrderQuantity type contract rejects implicit one fallback", () => {
  if (extractOrderQuantity("no numbers here") !== null) {
    throw new Error("extractOrderQuantity must not invent quantity");
  }
});
