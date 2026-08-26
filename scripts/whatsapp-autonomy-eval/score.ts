import type {
  EvalPair,
  EvalReport,
  GoldenCase,
  GroundTruth,
  ObservedResult,
} from "./types.ts";

const AUTO_OUTCOMES = new Set(["AUTO_ELIGIBLE"]);
const CLARIFICATION_OUTCOMES = new Set(["CLARIFICATION_REQUIRED"]);
const POLICY_OR_HUMAN_OUTCOMES = new Set([
  "POLICY_APPROVAL_REQUIRED",
  "HUMAN_EXCEPTION_REQUIRED",
]);
const FAILED_OUTCOMES = new Set(["FAILED_INTERPRETATION"]);

function normalizeUom(value: string | null): string | null {
  return value?.trim().toLowerCase() ?? null;
}

function fieldMatches(
  expected: string | null,
  observed: string | null,
): boolean {
  if (expected == null) return observed == null;
  return expected === observed;
}

function uomMatches(expected: string | null, observed: string | null): boolean {
  return normalizeUom(expected) === normalizeUom(observed);
}

function numericMatches(
  expected: number | null,
  observed: number | null,
): boolean {
  if (expected == null) return observed == null;
  if (observed == null) return false;
  return expected === observed;
}

export function isDangerousFalsePositive(pair: EvalPair): boolean {
  const { golden, observed } = pair;
  if (!observed.observed_auto_actioned) return false;
  const gt = golden.ground_truth;
  if (!gt.confirmed_so) return true;
  if (gt.intent !== "NEW_ORDER") return true;
  if (!gt.customer || !gt.sku || gt.quantity == null || gt.quantity <= 0) {
    return true;
  }
  if (!AUTO_OUTCOMES.has(observed.observed_core_outcome ?? "")) return true;
  if (observed.invented_commercial_leaked) return true;
  return false;
}

function isFalseOrder(pair: EvalPair): boolean {
  return pair.observed.observed_auto_actioned &&
    pair.golden.ground_truth.intent !== "NEW_ORDER";
}

function outcomeMismatch(pair: EvalPair): boolean {
  return (pair.observed.observed_core_outcome ?? "NULL") !==
    pair.golden.expected_core_outcome;
}

function autoActionMismatch(pair: EvalPair): boolean {
  return pair.observed.observed_auto_actioned !== pair.golden.should_auto_action;
}

function missingPotentialOrderAccounting(pair: EvalPair): boolean {
  if (!pair.observed.observed_auto_actioned) return false;
  if (!pair.golden.ground_truth.confirmed_so) return false;
  return pair.observed.potential_order_state !== "CONVERTED" ||
    pair.observed.potential_order_disposition !== "CONVERTED";
}

function commercialFieldViolations(pair: EvalPair): string[] {
  const violations: string[] = [];
  const { golden, observed } = pair;
  if (!observed.observed_auto_actioned || !golden.ground_truth.confirmed_so) {
    return violations;
  }
  const gt = golden.ground_truth;
  if (!fieldMatches(gt.customer, observed.observed_customer)) {
    violations.push(`${golden.id}: wrong customer auto-action`);
  }
  if (!fieldMatches(gt.branch, observed.observed_branch)) {
    violations.push(`${golden.id}: wrong branch auto-action`);
  }
  if (!fieldMatches(gt.sku, observed.observed_sku)) {
    violations.push(`${golden.id}: wrong SKU auto-action`);
  }
  if (!numericMatches(gt.quantity, observed.observed_quantity)) {
    violations.push(`${golden.id}: wrong quantity auto-action`);
  }
  if (!uomMatches(gt.uom, observed.observed_uom)) {
    violations.push(`${golden.id}: wrong UOM auto-action`);
  }
  if (observed.invented_commercial_leaked) {
    violations.push(`${golden.id}: invented commercial terms leaked`);
  }
  return violations;
}

function accuracyFor(
  pairs: EvalPair[],
  field: keyof GroundTruth,
  observedField: keyof ObservedResult,
): number {
  const scored = pairs.filter((pair) =>
    pair.golden.ground_truth[field] != null &&
    pair.observed.observed_auto_actioned
  );
  if (scored.length === 0) return 1;
  const correct = scored.filter((pair) => {
    const expected = pair.golden.ground_truth[field] as string | number | null;
    const observed = pair.observed[observedField] as string | number | null;
    if (field === "uom") return uomMatches(expected as string | null, observed as string | null);
    return expected === observed;
  }).length;
  return correct / scored.length;
}

export function scoreEvalPairs(pairs: EvalPair[]): EvalReport {
  const violations: string[] = [];
  const dangerous = pairs.filter(isDangerousFalsePositive).map((pair) =>
    pair.golden.id
  );
  const falseOrders = pairs.filter(isFalseOrder).map((pair) => pair.golden.id);
  const outcomeMismatches = pairs.filter(outcomeMismatch).map((pair) =>
    pair.golden.id
  );
  const autoMismatches = pairs.filter(autoActionMismatch).map((pair) =>
    pair.golden.id
  );
  const accountingMismatches = pairs.filter(missingPotentialOrderAccounting).map(
    (pair) => pair.golden.id,
  );

  for (const pair of pairs) {
    if (pair.observed.error) {
      violations.push(`${pair.golden.id}: execution error: ${pair.observed.error}`);
    }
    violations.push(...commercialFieldViolations(pair));
  }
  if (dangerous.length > 0) {
    violations.push(
      `dangerous automated commercial false positives: ${dangerous.join(", ")}`,
    );
  }
  if (falseOrders.length > 0) {
    violations.push(`false orders: ${falseOrders.join(", ")}`);
  }
  if (outcomeMismatches.length > 0) {
    violations.push(`outcome mismatches: ${outcomeMismatches.join(", ")}`);
  }
  if (autoMismatches.length > 0) {
    violations.push(`auto-action mismatches: ${autoMismatches.join(", ")}`);
  }
  if (accountingMismatches.length > 0) {
    violations.push(
      `missing potential-order accounting: ${accountingMismatches.join(", ")}`,
    );
  }

  const total = pairs.length;
  const auto = pairs.filter((pair) => pair.observed.observed_auto_actioned)
    .length;
  const trafficClassDistribution = pairs.reduce<Record<string, number>>(
    (acc, pair) => {
      acc[pair.golden.traffic_class] = (acc[pair.golden.traffic_class] ?? 0) +
        1;
      return acc;
    },
    {},
  );

  const clarification = pairs.filter((pair) =>
    CLARIFICATION_OUTCOMES.has(pair.observed.observed_core_outcome ?? "")
  ).length;
  const policyOrHuman = pairs.filter((pair) =>
    POLICY_OR_HUMAN_OUTCOMES.has(pair.observed.observed_core_outcome ?? "")
  ).length;
  const failed = pairs.filter((pair) =>
    FAILED_OUTCOMES.has(pair.observed.observed_core_outcome ?? "")
  ).length;

  return {
    total,
    traffic_class_distribution: trafficClassDistribution,
    auto_actioned: auto,
    straight_through_rate: total === 0 ? 0 : auto / total,
    clarification_rate: total === 0 ? 0 : clarification / total,
    policy_or_human_exception_rate: total === 0 ? 0 : policyOrHuman / total,
    failed_interpretation_rate: total === 0 ? 0 : failed / total,
    dangerous_false_positives: dangerous,
    dangerous_false_positive_rate: total === 0 ? 0 : dangerous.length / total,
    false_orders: falseOrders,
    outcome_mismatches: outcomeMismatches,
    customer_accuracy: accuracyFor(pairs, "customer", "observed_customer"),
    branch_accuracy: accuracyFor(pairs, "branch", "observed_branch"),
    sku_accuracy: accuracyFor(pairs, "sku", "observed_sku"),
    quantity_accuracy: accuracyFor(pairs, "quantity", "observed_quantity"),
    uom_accuracy: accuracyFor(pairs, "uom", "observed_uom"),
    blocked: violations.length > 0,
    violations,
  };
}

export function scoreSanitizedCorpus(
  goldenCases: GoldenCase[],
  observedResults: ObservedResult[],
): EvalReport {
  const observedById = new Map(
    observedResults.map((result) => [result.case_id, result]),
  );
  const pairs: EvalPair[] = goldenCases.map((golden) => {
    const observed = observedById.get(golden.id);
    if (!observed) {
      return {
        golden,
        observed: {
          case_id: golden.id,
          observed_core_outcome: null,
          observed_auto_actioned: false,
          observed_customer: null,
          observed_branch: null,
          observed_sku: null,
          observed_quantity: null,
          observed_uom: null,
          potential_order_state: null,
          potential_order_disposition: null,
          draft_id: null,
          promoted_order_id: null,
          selling_price: null,
          payment_terms: null,
          invented_commercial_leaked: false,
          idempotent_replay: false,
          error: "missing observed result",
        },
      };
    }
    return { golden, observed };
  });
  return scoreEvalPairs(pairs);
}

// Backward-compatible helper for unit tests that construct EvalPairs directly.
export function isDangerousFalsePositiveFromObserved(
  golden: GoldenCase,
  observed: ObservedResult,
): boolean {
  return isDangerousFalsePositive({ golden, observed });
}
