import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import fixture from "./fixtures/sanitized_golden_v1.json" with { type: "json" };
import { parseGoldenCorpus } from "./fixture_schema.ts";
import {
  isDangerousFalsePositiveFromObserved,
  scoreEvalPairs,
  scoreSanitizedCorpus,
} from "./score.ts";
import type { GoldenCase, ObservedResult } from "./types.ts";

const { cases } = parseGoldenCorpus(fixture);

function observedFromGolden(
  golden: GoldenCase,
  overrides: Partial<ObservedResult> = {},
): ObservedResult {
  return {
    case_id: golden.id,
    observed_core_outcome: golden.expected_core_outcome,
    observed_auto_actioned: golden.should_auto_action,
    observed_customer: golden.ground_truth.customer,
    observed_branch: golden.ground_truth.branch,
    observed_sku: golden.ground_truth.sku,
    observed_quantity: golden.ground_truth.quantity,
    observed_uom: golden.ground_truth.uom,
    potential_order_state: golden.should_auto_action ? "CONVERTED" : null,
    potential_order_disposition: golden.should_auto_action ? "CONVERTED" : null,
    draft_id: golden.should_auto_action ? "draft-1" : null,
    promoted_order_id: golden.should_auto_action ? "order-1" : null,
    selling_price: golden.id === "invented-discount-stripped-master-price-may-auto"
      ? 500
      : null,
    payment_terms: golden.id === "invented-discount-stripped-master-price-may-auto"
      ? "credit"
      : null,
    invented_commercial_leaked: false,
    idempotent_replay: false,
    error: null,
    ...overrides,
  };
}

Deno.test("fixture schema rejects observed runtime fields", () => {
  let threw = false;
  try {
    parseGoldenCorpus({
      corpus: "bad",
      cases: [{
        id: "bad",
        traffic_class: "x",
        input: {
          submitter_phone: "1",
          submitter_name: "x",
          provider_message_id: "p",
          message_body: "m",
          interpretation: {},
        },
        ground_truth: {
          intent: "NEW_ORDER",
          customer: null,
          branch: null,
          sku: null,
          quantity: null,
          uom: null,
          confirmed_so: false,
        },
        expected_core_outcome: "AUTO_ELIGIBLE",
        should_auto_action: true,
        core_outcome: "AUTO_ELIGIBLE",
      }],
    });
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});

Deno.test("scorer blocks when observed results are missing", () => {
  const golden = cases[0];
  const report = scoreSanitizedCorpus([golden], []);
  assertEquals(report.blocked, true);
  assertEquals(report.violations.some((v) => v.includes("missing observed result")), true);
});

Deno.test("matching observed Core results pass the sanitized corpus", () => {
  const observed = cases.map((golden) => observedFromGolden(golden));
  const report = scoreSanitizedCorpus(cases, observed);
  assertEquals(report.dangerous_false_positives, []);
  assertEquals(report.false_orders, []);
  assertEquals(report.outcome_mismatches, []);
  assertEquals(report.blocked, false);
});

Deno.test("mislabeled complaint auto-action is a dangerous false positive", () => {
  const golden = cases.find((row) => row.id === "complaint-not-an-order");
  if (!golden) throw new Error("missing complaint fixture");
  const observed = observedFromGolden(golden, {
    observed_core_outcome: "AUTO_ELIGIBLE",
    observed_auto_actioned: true,
  });
  assertEquals(isDangerousFalsePositiveFromObserved(golden, observed), true);
  const report = scoreSanitizedCorpus([golden], [observed]);
  assertEquals(report.blocked, true);
  assertEquals(report.false_orders, ["complaint-not-an-order"]);
});

Deno.test("outcome mismatch fails closed even without auto-action", () => {
  const golden = cases.find((row) => row.id === "missing-qty-must-not-default-1");
  if (!golden) throw new Error("missing qty fixture");
  const observed = observedFromGolden(golden, {
    observed_core_outcome: "AUTO_ELIGIBLE",
    observed_auto_actioned: false,
  });
  const report = scoreSanitizedCorpus([golden], [observed]);
  assertEquals(report.outcome_mismatches, ["missing-qty-must-not-default-1"]);
  assertEquals(report.blocked, true);
});

Deno.test("invented commercial leak blocks certification", () => {
  const golden = cases.find((row) =>
    row.id === "invented-discount-stripped-master-price-may-auto"
  );
  if (!golden) throw new Error("missing invented discount fixture");
  const observed = observedFromGolden(golden, {
    invented_commercial_leaked: true,
    payment_terms: "COD",
  });
  const report = scoreEvalPairs([{ golden, observed }]);
  assertEquals(report.blocked, true);
});

Deno.test("fixture corpus contains required Gate 10 scenarios", () => {
  const ids = new Set(cases.map((row) => row.id));
  for (
    const id of [
      "clear-order-employee-mediated",
      "family-term-midya",
      "missing-qty-must-not-default-1",
      "complaint-not-an-order",
      "dangerous-fp-probe-unclear-must-not-auto",
      "credit-frozen-policy-not-auto",
      "cancellation-requires-human",
      "payment-advice-not-an-order",
      "invented-discount-stripped-master-price-may-auto",
    ]
  ) {
    assertEquals(ids.has(id), true, `missing scenario ${id}`);
  }
  assertEquals(cases.length >= 12, true);
});
