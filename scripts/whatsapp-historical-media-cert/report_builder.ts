import type { HistoricalMediaReport, MediaCaseResult } from "./types.ts";
import { sanitizeWorkerStatus } from "./worker_status.ts";

export function buildHistoricalMediaReport(
  input: Omit<HistoricalMediaReport, "schema_version">,
): HistoricalMediaReport {
  return {
    schema_version: "wa-historical-media-cert/v1",
    ...input,
  };
}

const MEASURED_ZERO_TOLERANCE_KEYS = [
  "dangerous_media_false_positives",
  "false_autonomous_orders",
  "wrong_customer_autonomous_orders",
  "wrong_sku_autonomous_orders",
  "wrong_quantity_autonomous_orders",
  "wrong_uom_autonomous_orders",
  "commercial_invention_leakage",
  "silent_media_loss",
] as const;

/** Full PASS requires harness defects at or below this ceiling. */
export const HARNESS_DEFECT_PASS_CEILING = 0;

export function passVerdict(
  counters: Record<string, number | null>,
  reconciliationBalanced: boolean,
  successfulInterpretations: number,
  executedCases: number,
  replayPass: boolean,
  correctionPass: boolean,
  harnessDefectCount: number,
): "PASS" | "FAIL" {
  if (executedCases === 0 || successfulInterpretations === 0) return "FAIL";
  if (!replayPass) return "FAIL";
  if (!correctionPass) return "FAIL";
  if (harnessDefectCount > HARNESS_DEFECT_PASS_CEILING) return "FAIL";
  for (const key of MEASURED_ZERO_TOLERANCE_KEYS) {
    const value = counters[key];
    if (value != null && value !== 0) return "FAIL";
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
    worker_status: sanitizeWorkerStatus(result.worker_status),
    autonomy_outcome: result.persisted.autonomy_outcome,
    scores: result.scores,
    failure_class: result.failure_class,
    replay_idempotent: result.replay_idempotent,
  }));
}
