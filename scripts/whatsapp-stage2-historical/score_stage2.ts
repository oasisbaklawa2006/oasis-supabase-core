import type {
  EvalReport,
  GoldenCase,
  ObservedResult,
} from "../whatsapp-autonomy-eval/types.ts";
import { scoreSanitizedCorpus } from "../whatsapp-autonomy-eval/score.ts";
import type {
  CertificationWindow,
  ParsedHistoricalMessage,
  ReconciliationSummary,
  ZeroToleranceEntry,
} from "./types.ts";
import { mapObservedRoutingClass } from "./expectations.ts";
import { routingMatchesExpectation } from "./routing_contract.ts";
import { computeMessageAccounting } from "./message_accounting.ts";
import { sanitizeDefectRootCause } from "./privacy.ts";

export type Stage2Score = {
  coreReport: EvalReport;
  routing_match_rate: number;
  per_category_scores: Record<
    string,
    { count: number; match_rate: number | null }
  >;
  defects: Array<
    { case_id: string; expected: string; actual: string; root_cause: string }
  >;
  zero_tolerance: Record<string, ZeroToleranceEntry>;
  execution_gaps: string[];
  missing_observed_count: number;
};

export function buildReconciliationFromAccounting(
  messages: ParsedHistoricalMessage[],
  windows: CertificationWindow[],
): ReconciliationSummary {
  const windowedIndices = new Set(windows.map((w) => w.focal_index));
  const accounting = computeMessageAccounting(messages, windowedIndices);
  const mediaUnavailable =
    windows.filter((w) => w.expected_class === "MEDIA_UNAVAILABLE").length;
  const nonActionable = accounting.explicit_non_actionable_ack;

  return {
    received_business_messages: accounting.business_received,
    active_accounted: accounting.certification_windowed,
    converted: 0,
    duplicate_linked: 0,
    quarantined_media_unavailable: mediaUnavailable,
    explicitly_closed_non_actionable: nonActionable,
    excluded_system: accounting.system_excluded,
    excluded_deleted_only: accounting.deleted_business,
    unaccounted: accounting.unaccounted_business,
    balanced: accounting.balanced,
  };
}

function evaluatedCount(count: number): ZeroToleranceEntry {
  return { status: "evaluated", count };
}

export function buildZeroTolerance(
  coreReport: EvalReport,
  observed: ObservedResult[],
  replayViolations: string[],
  unaccountedBusinessMessages = 0,
): Record<string, ZeroToleranceEntry> {
  const draftIds = new Set<string>();
  let duplicateDrafts = 0;
  for (const row of observed) {
    if (!row.draft_id) continue;
    if (draftIds.has(row.draft_id)) duplicateDrafts += 1;
    draftIds.add(row.draft_id);
  }

  const promotedIds = observed
    .map((row) => row.promoted_order_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);
  const duplicateSo = promotedIds.length - new Set(promotedIds).size;

  return {
    invented_customer: evaluatedCount(
      coreReport.violations.filter((v) => v.includes("wrong customer")).length,
    ),
    invented_SKU: evaluatedCount(
      coreReport.violations.filter((v) => v.includes("wrong SKU")).length,
    ),
    invented_quantity: evaluatedCount(
      coreReport.violations.filter((v) => v.includes("wrong quantity")).length,
    ),
    invented_price: evaluatedCount(
      coreReport.violations.filter((v) => v.includes("invented commercial"))
        .length,
    ),
    invented_credit_approval: evaluatedCount(
      observed.filter((o) =>
        o.observed_auto_actioned &&
        (o.payment_terms === "credit" || o.payment_terms === "CREDIT")
      ).length +
        coreReport.violations.filter((v) => /credit/i.test(v)).length,
    ),
    false_payment_verification: evaluatedCount(
      observed.filter((o) =>
        o.observed_auto_actioned &&
        (o.payment_terms === "VERIFIED" || o.payment_terms === "PAID")
      ).length,
    ),
    dangerous_false_positive_order: evaluatedCount(
      coreReport.dangerous_false_positives.length,
    ),
    cross_customer_contamination: evaluatedCount(
      coreReport.violations.filter((v) => v.includes("cross")).length,
    ),
    silent_meaningful_message_loss: evaluatedCount(unaccountedBusinessMessages),
    correction_wrongly_suppressed: evaluatedCount(
      replayViolations.length +
        coreReport.violations.filter((v) => v.includes("idempotent")).length,
    ),
    unauthorized_commercial_disclosure: evaluatedCount(
      observed.filter((o) => o.invented_commercial_leaked).length,
    ),
    duplicate_governed_drafts: evaluatedCount(duplicateDrafts),
    duplicate_SO_outcomes: evaluatedCount(Math.max(0, duplicateSo)),
    unaccounted_potential_orders: evaluatedCount(
      coreReport.violations.filter((v) =>
        v.includes("missing potential-order accounting")
      ).length,
    ),
  };
}

export function zeroToleranceBlocksPass(
  zeroTolerance: Record<string, ZeroToleranceEntry>,
): boolean {
  for (const entry of Object.values(zeroTolerance)) {
    if (entry.status === "not_evaluated") return true;
    if (entry.count > 0) return true;
  }
  return false;
}

export function scoreStage2Historical(
  windows: CertificationWindow[],
  goldenCases: GoldenCase[],
  observed: ObservedResult[],
  replayViolations: string[] = [],
  unaccountedBusinessMessages = 0,
): Stage2Score {
  const observedById = new Map(observed.map((o) => [o.case_id, o]));
  const coreReport = scoreSanitizedCorpus(goldenCases, observed);
  const windowById = new Map(windows.map((w) => [w.window_id, w]));

  const per_category: Record<string, { count: number; matches: number }> = {};
  const defects: Stage2Score["defects"] = [];
  const execution_gaps: string[] = [];
  let routingMatches = 0;
  let routingScored = 0;
  let missing_observed_count = 0;

  for (const golden of goldenCases) {
    const window = windowById.get(golden.id);
    const obs = observedById.get(golden.id);
    if (!window) continue;

    if (!obs) {
      missing_observed_count += 1;
      execution_gaps.push(`missing observed result: ${golden.id}`);
      continue;
    }

    routingScored += 1;
    const bucket = window.expected_class;
    per_category[bucket] = per_category[bucket] ?? { count: 0, matches: 0 };
    per_category[bucket].count += 1;

    const routingOk = routingMatchesExpectation(
      window.expected_class,
      obs.observed_core_outcome,
      obs.observed_auto_actioned,
    );
    if (routingOk) {
      routingMatches += 1;
      per_category[bucket].matches += 1;
    } else {
      defects.push({
        case_id: golden.id,
        expected: window.expected_class,
        actual: mapObservedRoutingClass(
          obs.observed_core_outcome,
          obs.observed_auto_actioned,
        ),
        root_cause: sanitizeDefectRootCause(
          obs.observed_core_outcome,
          obs.observed_auto_actioned,
          obs.error,
        ),
      });
    }
  }

  const per_category_scores: Record<
    string,
    { count: number; match_rate: number | null }
  > = {};
  for (const [category, stats] of Object.entries(per_category)) {
    per_category_scores[category] = {
      count: stats.count,
      match_rate: stats.count === 0 ? null : stats.matches / stats.count,
    };
  }

  return {
    coreReport,
    routing_match_rate: routingScored === 0
      ? 0
      : routingMatches / routingScored,
    per_category_scores,
    defects,
    zero_tolerance: buildZeroTolerance(
      coreReport,
      observed,
      replayViolations,
      unaccountedBusinessMessages,
    ),
    execution_gaps,
    missing_observed_count,
  };
}

export function evergreenAssessment(
  windows: CertificationWindow[],
  defects: Stage2Score["defects"],
): {
  cluster_count: number;
  message_count: number;
  window_count: number;
  confirms_governed_model: number;
  adds_nuance: number;
  contradicts_assumption: number;
  insufficient_evidence: number;
  notes: string[];
} {
  const evergreenWindows = windows.filter((w) =>
    w.evergreen_cluster_id != null
  );
  const clusters = new Set(
    evergreenWindows.map((w) => w.evergreen_cluster_id).filter(
      Boolean,
    ) as string[],
  );
  const defectIds = new Set(defects.map((d) => d.case_id));
  let confirms = 0;
  let nuance = 0;
  let contradicts = 0;
  let insufficient = 0;
  const notes: string[] = [];

  for (const window of evergreenWindows) {
    if (defectIds.has(window.window_id)) {
      if (window.expected_class === "AMBIGUOUS_REQUIRES_HUMAN") {
        insufficient += 1;
        notes.push(
          `${window.window_id}: evergreen context remains ambiguous in export`,
        );
      } else {
        contradicts += 1;
      }
    } else if (window.linkage_reasons.includes("adjacent_party_context")) {
      nuance += 1;
    } else {
      confirms += 1;
    }
  }

  return {
    cluster_count: clusters.size,
    message_count: evergreenWindows.length,
    window_count: evergreenWindows.length,
    confirms_governed_model: confirms,
    adds_nuance: nuance,
    contradicts_assumption: contradicts,
    insufficient_evidence: insufficient,
    notes: notes.slice(0, 20),
  };
}

/** Stage 2 authority: governed routing match rate (not Stage 1B outcome parity). */
export function aggregateBenchmark(
  routingRate: number,
  _coreReport?: EvalReport,
): number {
  return routingRate;
}

/** Strip Stage 1B outcome-parity noise from core report before surfacing violations. */
export function stage2SanitizedViolations(
  coreReport: EvalReport,
  executionGaps: string[] = [],
): string[] {
  const filtered = coreReport.violations.filter((v) =>
    !v.startsWith("outcome mismatches:") &&
    !v.startsWith("auto-action mismatches:")
  );
  return [...executionGaps, ...filtered].slice(0, 50);
}

export function isOrderLikeClass(cls: string): boolean {
  return cls === "ORDER" || cls === "ORDER_AMENDMENT" ||
    cls === "ORDER_CANCELLATION";
}
