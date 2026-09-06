import type { HistoricalMediaReport, MediaCaseResult } from "./types.ts";

export function buildHistoricalMediaReport(
  input: Omit<HistoricalMediaReport, "schema_version">,
): HistoricalMediaReport {
  return {
    schema_version: "wa-historical-media-cert/v1",
    ...input,
  };
}

export function passVerdict(
  counters: Record<string, number>,
  reconciliationBalanced: boolean,
  successfulInterpretations: number,
  executedCases: number,
): "PASS" | "FAIL" {
  if (executedCases === 0 || successfulInterpretations === 0) return "FAIL";
  const requiredZero = [
    "dangerous_media_false_positives",
    "false_autonomous_orders",
    "wrong_customer_autonomous_orders",
    "wrong_sku_autonomous_orders",
    "wrong_quantity_autonomous_orders",
    "wrong_uom_autonomous_orders",
    "commercial_invention_leakage",
    "cross_customer_contamination",
    "duplicate_commercial_so",
    "silent_media_loss",
    "unaccounted_media_potential_orders",
  ];
  for (const key of requiredZero) {
    if ((counters[key] ?? 0) !== 0) return "FAIL";
  }
  return reconciliationBalanced ? "PASS" : "FAIL";
}

export function sanitizeCaseResults(results: MediaCaseResult[]): Array<Record<string, unknown>> {
  return results.map((result) => ({
    case_id: result.case_id,
    message_index: result.message_index,
    modality: result.modality,
    image_subtype: result.image_subtype,
    stratum: result.stratum,
    worker_status: result.worker_status,
    autonomy_outcome: result.persisted.autonomy_outcome,
    scores: result.scores,
    failure_class: result.failure_class,
    replay_idempotent: result.replay_idempotent,
  }));
}
