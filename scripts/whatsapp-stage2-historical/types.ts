import type { GoldenCase } from "../whatsapp-autonomy-eval/types.ts";

export const STAGE2_SCHEMA_VERSION = "wa-stage2-historical/v3";
export const PRIVACY_SANITIZATION_VERSION = "wa-stage2-privacy/v1";

/** Evidence-derived business expectation — not AI self-grade. */
export type ExpectedBusinessClass =
  | "ORDER"
  | "ORDER_AMENDMENT"
  | "ORDER_CANCELLATION"
  | "SO_REQUEST"
  | "SO_REFERENCE"
  | "PAYMENT_PROOF"
  | "PAYMENT_QUERY"
  | "DISPATCH_REQUEST"
  | "DISPATCH_STATUS"
  | "COMPLAINT"
  | "SHORTAGE"
  | "WRONG_QUANTITY"
  | "DELIVERY_ADDRESS"
  | "TRANSPORTER"
  | "SAMPLE_REQUEST"
  | "PI_REQUEST"
  | "INVOICE_LEDGER"
  | "CUSTOMISATION"
  | "INTERNAL_OPERATION"
  | "NON_ORDER_BUSINESS"
  | "AMBIGUOUS_REQUIRES_HUMAN"
  | "MEDIA_UNAVAILABLE"
  | "DELETED_MESSAGE"
  | "SYSTEM_EXCLUDED";

export type ParsedHistoricalMessage = {
  index: number;
  timestamp_raw: string;
  timestamp_ms: number | null;
  sender: string;
  body: string;
  is_forwarded: boolean;
  is_deleted: boolean;
  is_system: boolean;
  media_type: string | null;
  so_references: string[];
  party_hints: string[];
  mentions_evergreen: boolean;
};

export type CertificationWindow = {
  window_id: string;
  focal_index: number;
  message_indices: number[];
  sender: string;
  commercial_party_hint: string | null;
  expected_class: ExpectedBusinessClass;
  expected_core_outcome: string;
  should_auto_action: boolean;
  traffic_class: string;
  linkage_reasons: string[];
  evergreen_cluster_id: string | null;
};

export type IngestResult = {
  source_path: string;
  corpus_bytes: number;
  corpus_hash: string;
  messages: ParsedHistoricalMessage[];
  date_range: { start: string | null; end: string | null };
  unique_senders: number;
  commercial_party_contexts: number;
};

export type Stage2CaseBundle = {
  window: CertificationWindow;
  golden: GoldenCase;
};

export type ZeroToleranceEntry = {
  status: "evaluated" | "not_evaluated";
  count: number;
  reason?: string;
};

export type MessageAccountingSummary = {
  total_parsed: number;
  system_excluded: number;
  business_received: number;
  certification_windowed: number;
  explicit_non_actionable_ack: number;
  deleted_business: number;
  unparsed_sender_business: number;
  unaccounted_business: number;
  balanced: boolean;
};

export type ReconciliationSummary = {
  received_business_messages: number;
  active_accounted: number;
  converted: number;
  duplicate_linked: number;
  quarantined_media_unavailable: number;
  explicitly_closed_non_actionable: number;
  excluded_system: number;
  excluded_deleted_only: number;
  unaccounted: number;
  balanced: boolean;
};

export type EvergreenSubsetReport = {
  cluster_count: number;
  message_count: number;
  window_count: number;
  confirms_governed_model: number;
  adds_nuance: number;
  contradicts_assumption: number;
  insufficient_evidence: number;
  notes: string[];
};

export type Stage2HistoricalReport = {
  schema_version: typeof STAGE2_SCHEMA_VERSION;
  status: "BLOCKED" | "COMPLETE" | "FAILED" | "PROVISIONAL";
  final_verdict: "PASS" | "FAIL" | "BLOCKED" | "PROVISIONAL";
  declaration: string;
  blocker?: string;
  core_sha?: string;
  harness_sha?: string;
  routing_contract_version?: string;
  privacy_sanitization_version?: string;
  corpus_hash?: string;
  corpus_bytes: number;
  parsed_message_count: number;
  certification_window_count: number;
  executed_window_count?: number;
  excluded_window_count?: number;
  partial_run?: boolean;
  category_distribution: Record<string, number>;
  expected_class_distribution: Record<string, number>;
  historical_date_range: { start: string | null; end: string | null };
  unique_senders: number;
  commercial_party_contexts: number;
  aggregate_governed_benchmark: number | null;
  per_category_scores: Record<
    string,
    { count: number; match_rate: number | null }
  >;
  field_accuracy: Record<string, number | null>;
  zero_tolerance: Record<string, ZeroToleranceEntry>;
  dangerous_failure_counters: Record<string, number>;
  reconciliation: ReconciliationSummary;
  message_accounting?: MessageAccountingSummary;
  evergreen_subset: EvergreenSubsetReport;
  defects_found: Array<
    { case_id: string; expected: string; actual: string; root_cause: string }
  >;
  defects_fixed: string[];
  remaining_ambiguity_categories: Record<string, number>;
  excluded_cases: Array<{ case_id: string; reason: string }>;
  violations: string[];
  stage1b_regression: { status: string; note: string };
};
