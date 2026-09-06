import {
  HARNESS_DEFECT_PASS_CEILING,
  passVerdict,
  sanitizeCaseResults,
} from "./report_builder.ts";
import type { MediaCaseResult } from "./types.ts";

const baseCounters = {
  dangerous_media_false_positives: 0,
  false_autonomous_orders: 0,
  wrong_customer_autonomous_orders: 0,
  wrong_sku_autonomous_orders: 0,
  wrong_quantity_autonomous_orders: 0,
  wrong_uom_autonomous_orders: 0,
  commercial_invention_leakage: 0,
  silent_media_loss: 0,
};

Deno.test("passVerdict requires replay, correction, and bounded harness defects", () => {
  const pass = passVerdict(baseCounters, true, 10, 10, true, true, 0);
  if (pass !== "PASS") throw new Error("expected PASS");

  if (passVerdict(baseCounters, true, 10, 10, false, true, 0) !== "FAIL") {
    throw new Error("replay failure must fail verdict");
  }
  if (passVerdict(baseCounters, true, 10, 10, true, false, 0) !== "FAIL") {
    throw new Error("correction failure must fail verdict");
  }
  if (
    passVerdict(
      baseCounters,
      true,
      10,
      10,
      true,
      true,
      HARNESS_DEFECT_PASS_CEILING + 1,
    ) !== "FAIL"
  ) {
    throw new Error("unbounded harness defect must fail verdict");
  }
});

Deno.test("passVerdict rejects measured zero-tolerance violations", () => {
  const counters = { ...baseCounters, silent_media_loss: 1 };
  if (passVerdict(counters, true, 10, 10, true, true, 0) !== "FAIL") {
    throw new Error("expected zero-tolerance failure");
  }
});

Deno.test("sanitizeCaseResults allowlists worker_status", () => {
  const results: MediaCaseResult[] = [{
    case_id: "case-1",
    message_index: 1,
    modality: "IMAGE",
    image_subtype: "IMAGE_ONLY",
    stratum: "IMAGE:IMAGE_ONLY",
    packet_id: null,
    worker_status: "HIST_MEDIA_UPLOAD_FAILED:secret-path",
    persisted: {
      interpretation: null,
      autonomy_outcome: null,
      governed_facts: null,
      promoted_order_id: null,
    },
    recognition: {
      intent: null,
      sku: null,
      quantity: null,
      uom: null,
      customer_company_id: null,
    },
    scores: {
      intent_correct: null,
      customer_correct: null,
      product_family_correct: null,
      sku_correct: null,
      quantity_correct: null,
      uom_correct: null,
      pack_correct: null,
      auto_actioned: false,
      auto_action_correct: null,
      clarification_correct: null,
      invented_commercial_leakage: false,
      dangerous_false_positive: false,
      silent_media_loss: false,
    },
    failure_class: "HARNESS_DEFECT",
    replay_idempotent: null,
  }];
  const sanitized = sanitizeCaseResults(results);
  if (sanitized[0].worker_status !== "HIST_MEDIA_UPLOAD_FAILED") {
    throw new Error("expected allowlisted worker status without diagnostics");
  }
});
