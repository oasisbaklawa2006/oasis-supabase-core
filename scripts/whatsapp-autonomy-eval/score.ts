export type GroundTruth = {
  intent: string;
  customer: string | null;
  branch: string | null;
  sku: string | null;
  quantity: number | null;
  uom: string | null;
  confirmed_so: boolean;
};

export type EvalCase = {
  id: string;
  traffic_class: string;
  ground_truth: GroundTruth;
  core_outcome: string;
  auto_actioned: boolean;
};

export type EvalReport = {
  total: number;
  auto_actioned: number;
  dangerous_false_positives: string[];
  false_orders: string[];
  straight_through_rate: number;
  dangerous_false_positive_rate: number;
  blocked: boolean;
};

const AUTO_OUTCOMES = new Set(["AUTO_ELIGIBLE"]);

export function isDangerousFalsePositive(testCase: EvalCase): boolean {
  if (!testCase.auto_actioned) return false;
  const gt = testCase.ground_truth;
  if (!gt.confirmed_so) return true;
  if (gt.intent !== "NEW_ORDER") return true;
  if (!gt.customer || !gt.sku || gt.quantity == null || gt.quantity <= 0) {
    return true;
  }
  if (!AUTO_OUTCOMES.has(testCase.core_outcome)) return true;
  return false;
}

export function scoreSanitizedCorpus(cases: EvalCase[]): EvalReport {
  const dangerous = cases.filter(isDangerousFalsePositive).map((row) => row.id);
  const falseOrders = cases
    .filter((row) =>
      row.auto_actioned && row.ground_truth.intent !== "NEW_ORDER"
    )
    .map((row) => row.id);
  const auto = cases.filter((row) => row.auto_actioned).length;
  return {
    total: cases.length,
    auto_actioned: auto,
    dangerous_false_positives: dangerous,
    false_orders: falseOrders,
    straight_through_rate: cases.length === 0 ? 0 : auto / cases.length,
    dangerous_false_positive_rate: cases.length === 0
      ? 0
      : dangerous.length / cases.length,
    blocked: dangerous.length > 0,
  };
}
