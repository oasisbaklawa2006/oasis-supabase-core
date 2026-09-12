/**
 * Sanitized blocked-state certification evidence (no protected corpus required).
 */
import { buildHistoricalMediaReport } from "./report_builder.ts";
import {
  BLOCKED_VERDICT,
  CERTIFIED_MEDIA_ARCHIVE_BYTES,
  CERTIFIED_TEXT_HASH,
  MEDIA_AUTHORITY,
  MEDIA_SIDECAR_HASH,
  resolveCorpusPaths,
  verifyProtectedCorpusGate,
} from "./protected_corpus_gate.ts";
import {
  CANONICAL_V3_CERTIFICATION_WINDOWS,
  reconcileWindowAuthority,
} from "./window_authority.ts";

export const ARTIFACT_PATH = "artifacts/wa-historical-media/report.json";

const UNMEASURED_ZERO_TOLERANCE = [
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

const NULL_METRICS: Record<string, null> = {
  media_intent_accuracy: null,
  customer_resolution_accuracy: null,
  product_family_accuracy: null,
  exact_sku_accuracy: null,
  quantity_accuracy: null,
  uom_accuracy: null,
  pack_accuracy: null,
  media_straight_through_rate: null,
  image_only_intent_accuracy: null,
  image_only_exact_sku_accuracy: null,
  image_only_quantity_accuracy: null,
  image_only_uom_accuracy: null,
  image_only_stp: null,
  auto_action_precision: null,
  auto_action_recall: null,
  image_modality_intent_accuracy: null,
  pdf_modality_intent_accuracy: null,
  audio_modality_intent_accuracy: null,
  video_modality_intent_accuracy: null,
};

async function gitSha(ref: string): Promise<string> {
  try {
    const result = await new Deno.Command("git", {
      args: ["rev-parse", ref],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (!result.success) return "unknown";
    return new TextDecoder().decode(result.stdout).trim();
  } catch {
    return "unknown";
  }
}

export async function buildBlockedHistoricalMediaReport() {
  const gate = await verifyProtectedCorpusGate();
  const paths = resolveCorpusPaths();
  const headSha = await gitSha("HEAD");
  const mainSha = await gitSha("origin/main");
  const windowAuthority = reconcileWindowAuthority(CANONICAL_V3_CERTIFICATION_WINDOWS);

  const blocked = gate.status === "BLOCKED";
  const blockReason = blocked
    ? gate.reason
    : "Unexpected READY without certification execution on this runner.";

  return buildHistoricalMediaReport({
    status: "BLOCKED",
    final_verdict: blocked ? BLOCKED_VERDICT : "FAIL",
    starting_core_sha: headSha,
    final_head_sha: headSha,
    current_main_sha: mainSha,
    text_authority_hash: CERTIFIED_TEXT_HASH,
    media_sidecar_hash: MEDIA_SIDECAR_HASH,
    media_content_hash: blocked ? null : gate.media_content_hash,
    media_content_hash_status: blocked
      ? "BLOCKED_CORPUS_NOT_MOUNTED"
      : "OBSERVED_PENDING_PIN",
    media_content_hash_verified: blocked
      ? false
      : gate.media_content_hash_verified,
    media_binary_entry_count: blocked ? null : gate.media_binary_entry_count,
    media_archive_bytes_authority: CERTIFIED_MEDIA_ARCHIVE_BYTES,
    media_archive_bytes_observed: null,
    media_archive_bytes: null,
    protected_corpus_gate: blocked ? "BLOCKED" : "READY",
    protected_corpus_paths_expected: [paths.textZip, paths.mediaZip],
    protected_corpus_paths_missing: blocked ? gate.missing_paths : [],
    pairing_preflight: "NOT_EXECUTED",
    total_media_references: MEDIA_AUTHORITY.media_references,
    paired_references: MEDIA_AUTHORITY.paired_references,
    unpaired_detections: MEDIA_AUTHORITY.unpaired_detections,
    media_by_type: {
      IMAGE: 0,
      PDF: 0,
      AUDIO: 0,
      VIDEO: 0,
      OTHER: 0,
    },
    image_subtype_counts: {},
    window_authority: {
      ...windowAuthority,
      observed_v3_windows: null,
      reconciliation_note:
        "Pinned September v3 authority (8,804). Observed window count requires mounted corpus.",
    },
    eligible_media_cases: 0,
    executed_media_cases: 0,
    coverage_percentage: null,
    sampling_rule: "NOT_EXECUTED",
    image_only_cases: 0,
    metrics: NULL_METRICS,
    zero_tolerance_counters: Object.fromEntries(
      UNMEASURED_ZERO_TOLERANCE.map((key) => [key, null]),
    ),
    unmeasured_zero_tolerance_counters: UNMEASURED_ZERO_TOLERANCE,
    unmeasured_metrics: [
      "customer_resolution_accuracy",
      "product_family_accuracy",
      "pack_accuracy",
    ],
    correction_continuation_result: "NOT_EXECUTED",
    replay_result: "NOT_EXECUTED",
    reconciliation_result: "NOT_EXECUTED",
    failure_classification: {},
    pass_verdict_contract:
      "replay + correction_continuation + HARNESS_DEFECT ceiling + measured zero-tolerance + reconciliation",
    prior_certified_run_evidence:
      "artifacts/wa-historical-media/prior-certified-run-evidence.json",
    block_reason: blockReason,
    production_supabase_mutated: false,
    raw_corpus_in_git: false,
  });
}

export async function writeBlockedHistoricalMediaReport(
  path = ARTIFACT_PATH,
): Promise<void> {
  const report = await buildBlockedHistoricalMediaReport();
  await Deno.mkdir("artifacts/wa-historical-media", { recursive: true });
  await Deno.writeTextFile(path, `${JSON.stringify(report, null, 2)}\n`);
}

if (import.meta.main) {
  await writeBlockedHistoricalMediaReport();
  console.log(`BLOCKED_REPORT_WRITTEN:${ARTIFACT_PATH}`);
}
