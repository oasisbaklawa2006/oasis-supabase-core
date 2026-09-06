import type { CertificationWindow, ParsedHistoricalMessage } from "../whatsapp-stage2-historical/types.ts";
import type { ExpectationResult } from "../whatsapp-stage2-historical/expectations.ts";

export type MediaModality = "IMAGE" | "PDF" | "AUDIO" | "VIDEO" | "OTHER";

export type ImageSubtype =
  | "IMAGE_ONLY"
  | "IMAGE_WITH_CAPTION"
  | "SCREENSHOT"
  | "FORWARDED_SCREENSHOT"
  | "HANDWRITTEN_ORDER"
  | "PRODUCT_PHOTO"
  | "PRODUCT_LABEL_VISIBLE"
  | "CATALOGUE_SCREENSHOT"
  | "PURCHASE_ORDER_IMAGE"
  | "PAYMENT_PROOF"
  | "COMPLAINT_DAMAGE"
  | "MULTI_IMAGE"
  | "MEDIA_WITH_CORRECTION"
  | "AMBIGUOUS_OR_LOW_QUALITY";

export type GroundTruthField = string | number | null | "UNKNOWN";

export type HistoricalMediaGroundTruth = {
  intent: GroundTruthField;
  customer: GroundTruthField;
  branch: GroundTruthField;
  product_family: GroundTruthField;
  exact_sku: GroundTruthField;
  quantity: GroundTruthField;
  uom: GroundTruthField;
  pack: GroundTruthField;
  autonomous_safe: boolean | "UNKNOWN";
  clarification_required: boolean;
  human_exception_required: boolean;
  expected_core_outcome: string;
  expected_class: string;
};

export type PairedMediaReference = {
  case_id: string;
  message_index: number;
  archive_entry: string;
  modality: MediaModality;
  image_subtype: ImageSubtype | null;
  focal: ParsedHistoricalMessage;
  window: CertificationWindow | null;
  context_messages: ParsedHistoricalMessage[];
  expectation: ExpectationResult;
  ground_truth: HistoricalMediaGroundTruth;
  eligible: boolean;
  ineligible_reason: string | null;
  stratum: string;
};

export type MediaCaseResult = {
  case_id: string;
  message_index: number;
  modality: MediaModality;
  image_subtype: ImageSubtype | null;
  stratum: string;
  packet_id: string | null;
  worker_status: string;
  persisted: {
    interpretation: Record<string, unknown> | null;
    autonomy_outcome: string | null;
    governed_facts: Record<string, unknown> | null;
    promoted_order_id: string | null;
  };
  recognition: {
    intent: string | null;
    sku: string | null;
    quantity: number | null;
    uom: string | null;
    customer_company_id: string | null;
  };
  scores: {
    intent_correct: boolean | null;
    customer_correct: boolean | null;
    product_family_correct: boolean | null;
    sku_correct: boolean | null;
    quantity_correct: boolean | null;
    uom_correct: boolean | null;
    pack_correct: boolean | null;
    auto_actioned: boolean;
    auto_action_correct: boolean | null;
    clarification_correct: boolean | null;
    invented_commercial_leakage: boolean;
    dangerous_false_positive: boolean;
    silent_media_loss: boolean;
  };
  failure_class: string | null;
  replay_idempotent: boolean | null;
};

export type HistoricalMediaReport = {
  schema_version: string;
  status: "BLOCKED" | "COMPLETE" | "FAILED";
  final_verdict: "PASS" | "FAIL" | "PROTECTED_SEPTEMBER_MEDIA_SIDECAR_REQUIRED";
  starting_core_sha: string;
  final_head_sha: string;
  text_authority_hash: string;
  media_sidecar_hash: string;
  media_archive_bytes: number;
  protected_corpus_gate: string;
  pairing_preflight: string;
  total_media_references: number;
  paired_references: number;
  unpaired_detections: number;
  media_by_type: Record<MediaModality, number>;
  image_subtype_counts: Record<string, number>;
  image_subtype_counts: Record<string, number>;
  eligible_media_cases: number;
  executed_media_cases: number;
  coverage_percentage: number | null;
  sampling_rule: string;
  image_only_cases: number;
  metrics: Record<string, number | null>;
  zero_tolerance_counters: Record<string, number>;
  correction_continuation_result: string;
  replay_result: string;
  reconciliation_result: string;
  failure_classification: Record<string, number>;
  production_supabase_mutated: boolean;
  raw_corpus_in_git: boolean;
  case_results?: Array<Record<string, unknown>>;
  reconciliation?: Record<string, number>;
  current_main_sha?: string;
};
