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
