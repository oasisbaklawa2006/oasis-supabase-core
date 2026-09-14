import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  canonicalUom,
  recognitionFrom,
  uomEquivalent,
} from "./scoring.ts";

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

Deno.test("Stage1B recognition scores explicit SKU evidence without creating an order line", () => {
  const recognition = recognitionFrom({
    conclusion: {
      intent: "ENQUIRY",
      explicit_facts: [
        { provider_message_id: "m-1", kind: "sku", value: "BAK-PIST-250" },
        { provider_message_id: "m-1", kind: "claimed_unit_price", value: "Rs 1 only" },
      ],
      order_lines: [],
    },
  });

  assertEquals(recognition.sku, "BAK-PIST-250");
  assertEquals(recognition.quantity, null);
  assertEquals(recognition.uom, null);
});

Deno.test("Stage1B recognition never treats commercial claims as SKU evidence", () => {
  const recognition = recognitionFrom({
    conclusion: {
      intent: "ENQUIRY",
      explicit_facts: [
        { provider_message_id: "m-1", kind: "claimed_unit_price", value: "BAK-PIST-250 Rs 1" },
        { provider_message_id: "m-1", kind: "discount_claim", value: "99%" },
      ],
      order_lines: [],
    },
  });

  assertEquals(recognition.sku, null);
  assertEquals(recognition.product_name, null);
});
