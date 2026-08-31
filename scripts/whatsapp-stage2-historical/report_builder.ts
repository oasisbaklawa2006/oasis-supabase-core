import { buildCertificationWindows, distributionByClass } from "./segment.ts";
import { buildReconciliationFromAccounting } from "./score_stage2.ts";
import { computeMessageAccounting } from "./message_accounting.ts";
import { ROUTING_CONTRACT_VERSION } from "./routing_contract.ts";
import type { IngestResult, Stage2HistoricalReport } from "./types.ts";
import {
  PRIVACY_SANITIZATION_VERSION,
  STAGE2_SCHEMA_VERSION,
} from "./types.ts";
import type { CertificationWindow } from "./types.ts";

export const PROVISIONAL_PRE_CORE_BLOCKER =
  "Prior Stage 2 PASS invalidated after integrity repair; full Core DB evaluation rerun required before release use.";

export const PROVISIONAL_PRE_CORE_DECLARATION =
  "STAGE 2 HISTORICAL CORPUS — PRIOR PASS INVALIDATED; INTEGRITY REPAIR APPLIED; FULL CORE RERUN PENDING";

async function gitSha(ref: string): Promise<string | undefined> {
  try {
    const result = await new Deno.Command("git", {
      args: ["rev-parse", ref],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (!result.success) return undefined;
    return new TextDecoder().decode(result.stdout).trim();
  } catch {
    return undefined;
  }
}

/** Pre-Core-eval state after ingest + labeling (deterministic PROVISIONAL artifact). */
export async function buildPreCoreEvalProvisionalReport(
  ingest: IngestResult,
  windows: CertificationWindow[],
  coreSha?: string,
  harnessSha?: string,
): Promise<Stage2HistoricalReport> {
  const expectedDist = distributionByClass(windows);
  const evergreenWindows = windows.filter((w) =>
    w.evergreen_cluster_id != null
  );
  const windowedIndices = new Set(windows.map((w) => w.focal_index));
  const accounting = computeMessageAccounting(ingest.messages, windowedIndices);
  const reconciliation = buildReconciliationFromAccounting(
    ingest.messages,
    windows,
  );

  return {
    schema_version: STAGE2_SCHEMA_VERSION,
    status: "PROVISIONAL",
    final_verdict: "PROVISIONAL",
    declaration: PROVISIONAL_PRE_CORE_DECLARATION,
    blocker: PROVISIONAL_PRE_CORE_BLOCKER,
    core_sha: coreSha ?? await gitSha("HEAD"),
    harness_sha: harnessSha ??
      await gitSha("HEAD:scripts/whatsapp-stage2-historical"),
    routing_contract_version: ROUTING_CONTRACT_VERSION,
    privacy_sanitization_version: PRIVACY_SANITIZATION_VERSION,
    corpus_hash: ingest.corpus_hash,
    corpus_bytes: ingest.corpus_bytes,
    parsed_message_count: ingest.messages.length,
    certification_window_count: windows.length,
    executed_window_count: 0,
    excluded_window_count: 0,
    partial_run: false,
    category_distribution: {},
    expected_class_distribution: expectedDist as Record<string, number>,
    historical_date_range: ingest.date_range,
    unique_senders: ingest.unique_senders,
    commercial_party_contexts: ingest.commercial_party_contexts,
    aggregate_governed_benchmark: null,
    per_category_scores: {},
    field_accuracy: {},
    zero_tolerance: {},
    dangerous_failure_counters: {},
    reconciliation,
    message_accounting: accounting,
    evergreen_subset: {
      cluster_count:
        new Set(evergreenWindows.map((w) => w.evergreen_cluster_id)).size,
      message_count: evergreenWindows.length,
      window_count: evergreenWindows.length,
      confirms_governed_model: 0,
      adds_nuance: 0,
      contradicts_assumption: 0,
      insufficient_evidence: evergreenWindows.length,
      notes: ["Evergreen subset labeled; Core evaluation pending"],
    },
    defects_found: [],
    defects_fixed: [],
    remaining_ambiguity_categories: {},
    excluded_cases: [],
    violations: [],
    stage1b_regression: {
      status: "NOT_RERUN",
      note: "Stage 1B closed PASS; ingest-only path does not invoke Core",
    },
  };
}

export function buildBlockedReport(blocker: string): Stage2HistoricalReport {
  return {
    schema_version: STAGE2_SCHEMA_VERSION,
    status: "BLOCKED",
    final_verdict: "BLOCKED",
    declaration: "STAGE 2 HISTORICAL CORPUS — BLOCKED ON OWNER-PROVIDED CORPUS",
    blocker,
    privacy_sanitization_version: PRIVACY_SANITIZATION_VERSION,
    corpus_bytes: 0,
    parsed_message_count: 0,
    certification_window_count: 0,
    executed_window_count: 0,
    excluded_window_count: 0,
    partial_run: false,
    category_distribution: {},
    expected_class_distribution: {},
    historical_date_range: { start: null, end: null },
    unique_senders: 0,
    commercial_party_contexts: 0,
    aggregate_governed_benchmark: null,
    per_category_scores: {},
    field_accuracy: {},
    zero_tolerance: {},
    dangerous_failure_counters: {},
    reconciliation: {
      received_business_messages: 0,
      active_accounted: 0,
      converted: 0,
      duplicate_linked: 0,
      quarantined_media_unavailable: 0,
      explicitly_closed_non_actionable: 0,
      excluded_system: 0,
      excluded_deleted_only: 0,
      unaccounted: 0,
      balanced: false,
    },
    evergreen_subset: {
      cluster_count: 0,
      message_count: 0,
      window_count: 0,
      confirms_governed_model: 0,
      adds_nuance: 0,
      contradicts_assumption: 0,
      insufficient_evidence: 0,
      notes: [],
    },
    defects_found: [],
    defects_fixed: [],
    remaining_ambiguity_categories: {},
    excluded_cases: [],
    violations: [],
    stage1b_regression: {
      status: "PASS",
      note: "Stage 1B closed PASS; not re-run during Stage 2",
    },
  };
}

export function buildCertificationWindowsFromIngest(
  ingest: IngestResult,
): CertificationWindow[] {
  return buildCertificationWindows(ingest.messages);
}
