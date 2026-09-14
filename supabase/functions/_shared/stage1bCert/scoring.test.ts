import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { canonicalUom, uomEquivalent } from "./scoring.ts";

Deno.test("Stage1B UOM scoring treats governed box spellings as equivalent", () => {
  for (const value of ["Box", "box", "boxes", "BX", "bxs"]) {
    assertEquals(canonicalUom(value), "box");
    assertEquals(uomEquivalent("Box", value), true);
  }
});

Deno.test("Stage1B UOM scoring preserves material unit differences", () => {
  assertEquals(uomEquivalent("Box", "pcs"), false);
  assertEquals(uomEquivalent("kg", "kilograms"), true);
  assertEquals(uomEquivalent("g", "grams"), true);
  assertEquals(uomEquivalent(null, "boxes"), null);
});
