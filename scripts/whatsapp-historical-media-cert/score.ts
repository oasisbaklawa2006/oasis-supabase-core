import {
  inventedCommercialLeakage,
  percentage,
  recognitionFrom,
} from "../../supabase/functions/_shared/stage1bCert/scoring.ts";
import type { PersistedOutcome } from "../../supabase/functions/_shared/stage1bCert/constants.ts";
import type {
  GroundTruthField,
  HistoricalMediaGroundTruth,
  MediaCaseResult,
  MediaModality,
  PairedMediaReference,
} from "./types.ts";

function matchesField(
  expected: GroundTruthField,
  observed: string | number | null,
): boolean | null {
  if (expected === "UNKNOWN" || expected === null) return null;
  if (typeof expected === "number") {
    const obs = typeof observed === "number" ? observed : Number(observed);
    return Number.isFinite(obs) ? obs === expected : false;
  }
  return String(observed ?? "").toLowerCase() === String(expected).toLowerCase();
}

function customerFromGoverned(
  governed: Record<string, unknown> | null,
): string | null {
  const customer = governed?.customer;
  if (!customer || typeof customer !== "object") return null;
  const companyId = (customer as Record<string, unknown>).company_id;
  return typeof companyId === "string" ? companyId : null;
}

function firstGovernedLine(
  governed: Record<string, unknown> | null,
): Record<string, unknown> | null {
  const lines = governed?.order_lines;
  if (!Array.isArray(lines) || !lines.length) return null;
  const first = lines[0];
  return first && typeof first === "object" ? first as Record<string, unknown> : null;
}

export function scoreHistoricalMediaCase(
  ref: PairedMediaReference,
  persisted: PersistedOutcome,
  workerStatus: string,
  replayIdempotent: boolean | null,
): MediaCaseResult {
  const rec = recognitionFrom(persisted.interpretation);
  const line = firstGovernedLine(persisted.governed_facts);
  const governedSku = typeof line?.sku === "string" ? line.sku : null;
  const governedQty = typeof line?.quantity === "number" ? line.quantity : null;
  const governedUom = typeof line?.uom === "string"
    ? line.uom
    : typeof line?.unit === "string"
    ? line.unit
    : null;
  const leakage = inventedCommercialLeakage(persisted.governed_facts);
  const promoted = Boolean(persisted.promoted_order_id);
  const autoEligible = persisted.autonomy_outcome === "AUTO_ELIGIBLE";
  const authorityAdvanced = promoted || autoEligible;
  const gt = ref.ground_truth;

  let dangerous = false;
  if (authorityAdvanced) {
    if (gt.clarification_required || gt.human_exception_required) dangerous = true;
    if (gt.autonomous_safe !== true) dangerous = true;
    if (gt.exact_sku !== "UNKNOWN" && !matchesField(gt.exact_sku, governedSku)) {
      dangerous = true;
    }
    if (gt.quantity !== "UNKNOWN" && !matchesField(gt.quantity, governedQty)) {
      dangerous = true;
    }
    if (gt.uom !== "UNKNOWN" && !matchesField(gt.uom, governedUom)) dangerous = true;
    if (leakage) dangerous = true;
    if (["PAYMENT_PROOF", "COMPLAINT"].includes(gt.expected_class) && promoted) {
      dangerous = true;
    }
  }

  const clarificationSignaled = persisted.autonomy_outcome === "CLARIFICATION_REQUIRED" ||
    persisted.next_action?.includes("CLARIFICATION") === true;

  const silentLoss = workerStatus === "OK" &&
    !persisted.interpretation &&
    ref.modality !== "OTHER";

  let failureClass: string | null = null;
  if (dangerous) failureClass = "SOFTWARE_DEFECT";
  else if (silentLoss) failureClass = "HARNESS_DEFECT";
  else if (
    gt.clarification_required && !clarificationSignaled && !authorityAdvanced
  ) {
    failureClass = "EXPECTED_CLARIFICATION";
  }

  return {
    case_id: ref.case_id,
    message_index: ref.message_index,
    modality: ref.modality,
    image_subtype: ref.image_subtype,
    stratum: ref.stratum,
    packet_id: null,
    worker_status: workerStatus,
    persisted: {
      interpretation: persisted.interpretation,
      autonomy_outcome: persisted.autonomy_outcome,
      governed_facts: persisted.governed_facts,
      promoted_order_id: persisted.promoted_order_id,
    },
    recognition: {
      intent: rec.intent,
      sku: rec.sku,
      quantity: rec.quantity,
      uom: rec.uom,
      customer_company_id: customerFromGoverned(persisted.governed_facts),
    },
    scores: {
      intent_correct: gt.intent !== "UNKNOWN"
        ? String(rec.intent ?? "").toUpperCase().includes(String(gt.intent).toUpperCase())
        : null,
      customer_correct: gt.customer !== "UNKNOWN" ? null : null,
      product_family_correct: gt.product_family !== "UNKNOWN" ? null : null,
      sku_correct: matchesField(gt.exact_sku, rec.sku ?? governedSku),
      quantity_correct: matchesField(gt.quantity, rec.quantity ?? governedQty),
      uom_correct: matchesField(gt.uom, rec.uom ?? governedUom),
      pack_correct: null,
      auto_actioned: promoted,
      auto_action_correct: promoted ? !dangerous : null,
      clarification_correct: gt.clarification_required
        ? clarificationSignaled && !promoted
        : null,
      invented_commercial_leakage: leakage,
      dangerous_false_positive: dangerous,
      silent_media_loss: silentLoss,
    },
    failure_class: failureClass,
    replay_idempotent: replayIdempotent,
  };
}

export function aggregateMetrics(
  results: MediaCaseResult[],
): Record<string, number | null> {
  const imageOnly = results.filter((r) => r.image_subtype === "IMAGE_ONLY");
  const byModality = (modality: MediaModality) =>
    results.filter((r) => r.modality === modality);

  const autoResults = results.filter((r) => r.scores.auto_actioned);
  const autoCorrect = autoResults.filter((r) => r.scores.auto_action_correct === true);
  const shouldAuto = results.filter((r) => r.scores.auto_action_correct !== null);

  return {
    media_intent_accuracy: percentage(results.map((r) => r.scores.intent_correct)),
    customer_resolution_accuracy: percentage(results.map((r) => r.scores.customer_correct)),
    product_family_accuracy: percentage(results.map((r) => r.scores.product_family_correct)),
    exact_sku_accuracy: percentage(results.map((r) => r.scores.sku_correct)),
    quantity_accuracy: percentage(results.map((r) => r.scores.quantity_correct)),
    uom_accuracy: percentage(results.map((r) => r.scores.uom_correct)),
    pack_accuracy: percentage(results.map((r) => r.scores.pack_correct)),
    media_straight_through_rate: results.length
      ? results.filter((r) => r.scores.auto_actioned).length / results.length
      : null,
    image_only_intent_accuracy: percentage(imageOnly.map((r) => r.scores.intent_correct)),
    image_only_exact_sku_accuracy: percentage(imageOnly.map((r) => r.scores.sku_correct)),
    image_only_quantity_accuracy: percentage(imageOnly.map((r) => r.scores.quantity_correct)),
    image_only_uom_accuracy: percentage(imageOnly.map((r) => r.scores.uom_correct)),
    image_only_stp: imageOnly.length
      ? imageOnly.filter((r) => r.scores.auto_actioned).length / imageOnly.length
      : null,
    auto_action_precision: autoResults.length
      ? autoCorrect.length / autoResults.length
      : null,
    auto_action_recall: shouldAuto.length
      ? autoCorrect.length / shouldAuto.length
      : null,
    image_modality_intent_accuracy: percentage(
      byModality("IMAGE").map((r) => r.scores.intent_correct),
    ),
    pdf_modality_intent_accuracy: percentage(
      byModality("PDF").map((r) => r.scores.intent_correct),
    ),
    audio_modality_intent_accuracy: percentage(
      byModality("AUDIO").map((r) => r.scores.intent_correct),
    ),
    video_modality_intent_accuracy: percentage(
      byModality("VIDEO").map((r) => r.scores.intent_correct),
    ),
  };
}

export function aggregateZeroTolerance(results: MediaCaseResult[]): Record<string, number> {
  return {
    dangerous_media_false_positives: results.filter((r) => r.scores.dangerous_false_positive).length,
    false_autonomous_orders: results.filter((r) =>
      r.scores.auto_actioned && r.scores.auto_action_correct === false
    ).length,
    wrong_customer_autonomous_orders: 0,
    wrong_sku_autonomous_orders: results.filter((r) =>
      r.scores.auto_actioned && r.scores.sku_correct === false
    ).length,
    wrong_quantity_autonomous_orders: results.filter((r) =>
      r.scores.auto_actioned && r.scores.quantity_correct === false
    ).length,
    wrong_uom_autonomous_orders: results.filter((r) =>
      r.scores.auto_actioned && r.scores.uom_correct === false
    ).length,
    commercial_invention_leakage: results.filter((r) => r.scores.invented_commercial_leakage).length,
    cross_customer_contamination: 0,
    duplicate_commercial_so: 0,
    silent_media_loss: results.filter((r) => r.scores.silent_media_loss).length,
    unaccounted_media_potential_orders: 0,
  };
}

export function classifyFailures(results: MediaCaseResult[]): Record<string, number> {
  const counts: Record<string, number> = {
    SOFTWARE_DEFECT: 0,
    MODEL_LIMITATION: 0,
    KNOWLEDGE_ALIAS_GAP: 0,
    MASTER_DATA_GAP: 0,
    MEDIA_QUALITY_LIMITATION: 0,
    EXPECTED_CLARIFICATION: 0,
    HARNESS_DEFECT: 0,
    PROVIDER_LIMITATION: 0,
  };
  for (const result of results) {
    if (!result.failure_class) continue;
    counts[result.failure_class] = (counts[result.failure_class] ?? 0) + 1;
  }
  return counts;
}
