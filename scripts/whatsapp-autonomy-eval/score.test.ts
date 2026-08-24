import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import fixture from "./fixtures/sanitized_golden_v1.json" with { type: "json" };
import {
  type EvalCase,
  isDangerousFalsePositive,
  scoreSanitizedCorpus,
} from "./score.ts";

const cases = fixture.cases as EvalCase[];

Deno.test("sanitized corpus never auto-actions unclear, complaint, or missing quantity", () => {
  const report = scoreSanitizedCorpus(cases);
  assertEquals(report.dangerous_false_positives, []);
  assertEquals(report.false_orders, []);
  assertEquals(report.blocked, false);
  assertEquals(report.dangerous_false_positive_rate, 0);
});

Deno.test("clear employee-mediated order may be AUTO_ELIGIBLE", () => {
  const clear = cases.find((row) => row.id === "clear-order-employee-mediated");
  if (!clear) throw new Error("missing clear-order fixture");
  assertEquals(isDangerousFalsePositive(clear), false);
  assertEquals(clear.core_outcome, "AUTO_ELIGIBLE");
});

Deno.test("adversarial missing quantity is not a dangerous auto-action", () => {
  const missing = cases.find((row) =>
    row.id === "missing-qty-must-not-default-1"
  );
  if (!missing) throw new Error("missing qty fixture");
  assertEquals(missing.auto_actioned, false);
  assertEquals(isDangerousFalsePositive(missing), false);
});

Deno.test("policy, cancellation, and payment advice stay non-auto", () => {
  for (
    const id of [
      "credit-frozen-policy-not-auto",
      "cancellation-requires-human",
      "payment-advice-not-an-order",
    ]
  ) {
    const row = cases.find((testCase) => testCase.id === id);
    if (!row) throw new Error(`missing fixture ${id}`);
    assertEquals(row.auto_actioned, false);
    assertEquals(isDangerousFalsePositive(row), false);
  }
});

Deno.test("invented discount does not become a dangerous false positive when Core uses master price", () => {
  const row = cases.find((testCase) =>
    testCase.id === "invented-discount-stripped-master-price-may-auto"
  );
  if (!row) throw new Error("missing invented-discount fixture");
  assertEquals(row.core_outcome, "AUTO_ELIGIBLE");
  assertEquals(isDangerousFalsePositive(row), false);
});

Deno.test("mislabeled auto-action of a complaint is a dangerous false positive", () => {
  const probe: EvalCase = {
    id: "mislabeled-complaint-auto",
    traffic_class: "non_order",
    ground_truth: {
      intent: "COMPLAINT",
      customer: "CUST-ACTIVE-003",
      branch: null,
      sku: null,
      quantity: null,
      uom: null,
      confirmed_so: false,
    },
    core_outcome: "AUTO_ELIGIBLE",
    auto_actioned: true,
  };
  assertEquals(isDangerousFalsePositive(probe), true);
  const report = scoreSanitizedCorpus([probe]);
  assertEquals(report.blocked, true);
  assertEquals(report.false_orders, ["mislabeled-complaint-auto"]);
});
