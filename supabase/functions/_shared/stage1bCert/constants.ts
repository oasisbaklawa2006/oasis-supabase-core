/** @file Stage-1B preview certification constants — NON-PRODUCTION ONLY. */

export const PREVIEW_CERT_PROJECT_REF = "jyezfiehhfgnvhzzffxr";
export const FORBIDDEN_PRODUCTION_REF = "tcxvcatsqqertcnycuop";
export const CERT_RUNNER_VERSION = "wa-stage1b-preview-runner/v1";
export const REPORT_SCHEMA_VERSION = "wa-stage1b-report/v3";
export const BUCKET = "wa-stage1b-cert";
export const WORKER_PROBE_TIMEOUT_MS = 15_000;
export const WORKER_INVOCATION_TIMEOUT_MS = 90_000;
export const MAX_PACKET_MESSAGES = 16;

export type Fixture = {
  id: string;
  file?: string;
  files?: string[];
  media_type: string;
  caption?: string | null;
  follow_up_text?: string;
  optional?: boolean;
  ground_truth: Record<string, unknown>;
};

export type PersistedOutcome = {
  interpretation_id: string | null;
  interpretation: Record<string, unknown> | null;
  autonomy_outcome: string | null;
  governed_facts: Record<string, unknown> | null;
  case_id: string | null;
  case_type: string | null;
  case_status: string | null;
  next_action: string | null;
  draft_id: string | null;
  draft_status: string | null;
  promoted_order_id: string | null;
};

export type FixtureResult = {
  fixture_id: string;
  packet_id: string;
  provider_message_ids: string[];
  ground_truth: Record<string, unknown>;
  worker: Record<string, unknown>;
  persisted: PersistedOutcome;
  recognition: {
    intent: string | null;
    sku: string | null;
    product_name: string | null;
    quantity: number | null;
    uom: string | null;
  };
  scores: {
    intent_correct: boolean | null;
    product_family_correct: boolean | null;
    sku_correct: boolean | null;
    quantity_correct: boolean | null;
    uom_correct: boolean | null;
    clarification_correct: boolean | null;
    auto_actioned: boolean;
    auto_action_correct: boolean | null;
    invented_commercial_leakage: boolean;
    dangerous_false_positive: boolean;
  };
};

export type GateResult = {
  gate: "A" | "B" | "C" | "D" | "E";
  status: "PASS" | "FAIL" | "BLOCKED" | "SKIP";
  detail?: string;
  metrics?: Record<string, number | boolean | null>;
};

export type HarnessReport = {
  schema_version: typeof REPORT_SCHEMA_VERSION;
  status: "BLOCKED" | "COMPLETE" | "FAILED";
  final_verdict?: "PASS" | "FAIL";
  blocker?: string;
  core_sha?: string;
  cert_branch_sha?: string;
  preview_project_ref: string;
  cert_runner_version: string;
  run_id: string;
  runtime_secret_readiness: Record<string, boolean>;
  fixture_count: number;
  image_only_count: number;
  pdf_count: number;
  audio_count: number;
  video_count: number;
  worker_invocations: number;
  dangerous_media_false_positives: number;
  invented_commercial_leakage: number;
  silent_media_loss: number;
  gates: GateResult[];
  metrics?: Record<string, number | null>;
  results: FixtureResult[];
  reconciliation?: Record<string, number>;
  adversarial?: Record<string, unknown>;
};
