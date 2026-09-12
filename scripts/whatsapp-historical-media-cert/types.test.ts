import { buildBlockedHistoricalMediaReport } from "./blocked_report.ts";
import { buildHistoricalMediaReport, passVerdict } from "./report_builder.ts";
import type { HistoricalMediaReport } from "./types.ts";

Deno.test("HistoricalMediaReport type accepts blocked-state report without duplicate fields", () => {
  const report: HistoricalMediaReport = buildHistoricalMediaReport({
    status: "BLOCKED",
    final_verdict: "PROTECTED_SEPTEMBER_MEDIA_SIDECAR_REQUIRED",
    starting_core_sha: "abc",
    final_head_sha: "abc",
    text_authority_hash: "text",
    media_sidecar_hash: "media",
    media_archive_bytes: null,
    protected_corpus_gate: "BLOCKED",
    pairing_preflight: "NOT_EXECUTED",
    total_media_references: 2441,
    paired_references: 2376,
    unpaired_detections: 65,
    media_by_type: { IMAGE: 0, PDF: 0, AUDIO: 0, VIDEO: 0, OTHER: 0 },
    image_subtype_counts: {},
    eligible_media_cases: 0,
    executed_media_cases: 0,
    coverage_percentage: null,
    sampling_rule: "NOT_EXECUTED",
    image_only_cases: 0,
    metrics: {},
    zero_tolerance_counters: {},
    correction_continuation_result: "NOT_EXECUTED",
    replay_result: "NOT_EXECUTED",
    reconciliation_result: "NOT_EXECUTED",
    failure_classification: {},
    production_supabase_mutated: false,
    raw_corpus_in_git: false,
  });
  if (report.status !== "BLOCKED") throw new Error("expected BLOCKED status");
  if (report.final_verdict === "PASS") throw new Error("blocked report must not PASS");
});

Deno.test("certification path type-checks report_builder against HistoricalMediaReport", () => {
  const verdict = passVerdict({}, true, 1, 1, true, true, 0);
  if (verdict !== "PASS" && verdict !== "FAIL") {
    throw new Error("unexpected verdict type");
  }
});

Deno.test("blocked report is fail-closed without protected corpus mount", async () => {
  const report = await buildBlockedHistoricalMediaReport();
  if (report.status !== "BLOCKED") throw new Error(`expected BLOCKED, got ${report.status}`);
  if (report.final_verdict === "PASS") throw new Error("blocked report must not claim PASS");
  if (report.protected_corpus_gate !== "BLOCKED") {
    throw new Error("expected protected corpus gate BLOCKED");
  }
  if (report.media_content_hash_status !== "BLOCKED_CORPUS_NOT_MOUNTED") {
    throw new Error("expected blocked media content hash status");
  }
  if (report.media_content_hash_verified !== false) {
    throw new Error("content hash must not be verified without mount");
  }
  if (report.media_archive_bytes_observed !== null) {
    throw new Error("observed archive bytes must be null without mount");
  }
  if (report.executed_media_cases !== 0) {
    throw new Error("no cases may execute without corpus");
  }
  if (report.correction_continuation_result !== "NOT_EXECUTED") {
    throw new Error("correction continuation must be NOT_EXECUTED");
  }
});
