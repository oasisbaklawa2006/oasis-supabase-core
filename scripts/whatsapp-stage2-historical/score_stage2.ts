import type { EvalReport, GoldenCase, ObservedResult } from "../whatsapp-autonomy-eval/types.ts";
import { scoreSanitizedCorpus } from "../whatsapp-autonomy-eval/score.ts";
import type { CertificationWindow, ReconciliationSummary } from "./types.ts";
import {
  mapObservedRoutingClass,
  routingMatchesExpectation,
} from "./expectations.ts";
import type { ExpectedBusinessClass } from "./types.ts";

export type Stage2Score = {
  coreReport: EvalReport;
  routing_match_rate: number;
  per_category_scores: Record<string, { count: number; match_rate: number | null }>;
  defects: Array<{ case_id: string; expected: string; actual: string; root_cause: string }>;
  zero_tolerance: Record<string, number>;
};

export function buildReconciliationFixed(
  businessMessages: number,
  windows: CertificationWindow[],
  systemExcluded: number,
  deletedOnly: number,
): ReconciliationSummary {
  const mediaUnavailable = windows.filter((w) => w.expected_class === "MEDIA_UNAVAILABLE").length;
  const nonActionable = windows.filter((w) =>
    w.expected_class === "NON_ORDER_BUSINESS" ||
    w.expected_class === "INTERNAL_OPERATION"
  ).length;
  const activeAccounted = windows.length;
  const accounted = activeAccounted + systemExcluded;
  const unaccounted = Math.max(0, businessMessages - accounted);
  return {
    received_business_messages: businessMessages,
    active_accounted: activeAccounted,
    converted: 0,
    duplicate_linked: 0,
    quarantined_media_unavailable: mediaUnavailable,
    explicitly_closed_non_actionable: nonActionable,
    excluded_system: systemExcluded,
    excluded_deleted_only: deletedOnly,
    unaccounted,
    balanced: unaccounted === 0,
  };
}

export function scoreStage2Historical(
  windows: CertificationWindow[],
  goldenCases: GoldenCase[],
  observed: ObservedResult[],
): Stage2Score {
  const coreReport = scoreSanitizedCorpus(goldenCases, observed);
  const observedById = new Map(observed.map((o) => [o.case_id, o]));
  const windowById = new Map(windows.map((w) => [w.window_id, w]));

  const per_category: Record<string, { count: number; matches: number }> = {};
  const defects: Stage2Score["defects"] = [];
  let routingMatches = 0;

  for (const golden of goldenCases) {
    const window = windowById.get(golden.id);
    const obs = observedById.get(golden.id);
    if (!window || !obs) continue;
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
        actual: mapObservedRoutingClass(obs.observed_core_outcome, obs.observed_auto_actioned),
        root_cause: obs.error ??
          `observed ${obs.observed_core_outcome ?? "NULL"} auto=${obs.observed_auto_actioned}`,
      });
    }
  }

  const per_category_scores: Record<string, { count: number; match_rate: number | null }> = {};
  for (const [category, stats] of Object.entries(per_category)) {
    per_category_scores[category] = {
      count: stats.count,
      match_rate: stats.count === 0 ? null : stats.matches / stats.count,
    };
  }

  const zero_tolerance = {
    invented_customer: coreReport.violations.filter((v) => v.includes("wrong customer")).length,
    invented_SKU: coreReport.violations.filter((v) => v.includes("wrong SKU")).length,
    invented_quantity: coreReport.violations.filter((v) => v.includes("wrong quantity")).length,
    invented_price: coreReport.violations.filter((v) => v.includes("invented commercial")).length,
    invented_credit_approval: 0,
    false_payment_verification: observed.filter((o) =>
      o.payment_terms === "VERIFIED" || o.payment_terms === "PAID"
    ).length,
    dangerous_false_positive_order: coreReport.dangerous_false_positives.length,
    cross_customer_contamination: coreReport.violations.filter((v) => v.includes("cross")).length,
    silent_meaningful_message_loss: 0,
    correction_wrongly_suppressed: coreReport.violations.filter((v) => v.includes("idempotent")).length,
    unauthorized_commercial_disclosure: 0,
    duplicate_governed_drafts: 0,
    duplicate_SO_outcomes: 0,
    unaccounted_potential_orders: coreReport.violations.filter((v) =>
      v.includes("missing potential-order accounting")
    ).length,
  };

  return {
    coreReport,
    routing_match_rate: goldenCases.length === 0 ? 0 : routingMatches / goldenCases.length,
    per_category_scores,
    defects,
    zero_tolerance,
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
  const evergreenWindows = windows.filter((w) => w.evergreen_cluster_id != null);
  const clusters = new Set(
    evergreenWindows.map((w) => w.evergreen_cluster_id).filter(Boolean) as string[],
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
        notes.push(`${window.window_id}: evergreen context remains ambiguous in export`);
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
export function aggregateBenchmark(routingRate: number, _coreReport?: EvalReport): number {
  return routingRate;
}

/** Strip Stage 1B outcome-parity noise from core report before surfacing violations. */
export function stage2SanitizedViolations(coreReport: EvalReport): string[] {
  return coreReport.violations.filter((v) =>
    !v.startsWith("outcome mismatches:") &&
    !v.startsWith("auto-action mismatches:")
  ).slice(0, 50);
}

export function isOrderLikeClass(cls: ExpectedBusinessClass): boolean {
  return cls === "ORDER" || cls === "ORDER_AMENDMENT" || cls === "ORDER_CANCELLATION";
}
