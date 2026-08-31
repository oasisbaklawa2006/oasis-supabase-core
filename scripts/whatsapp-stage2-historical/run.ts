/**
 * Stage 2 — historical Oasis B2B WhatsApp corpus certification.
 *
 * Accepts authorized raw WhatsApp export (.txt or .zip containing _chat.txt)
 * via WA_PROTECTED_CORPUS_PATH. Never commits or logs raw corpus content.
 */
import { validateCertDatabaseTarget } from "../whatsapp-autonomy-eval/database_target.ts";
import { buildCertificationWindows, distributionByClass } from "./segment.ts";
import { ingestHistoricalCorpus, summarizeIngest } from "./ingest.ts";
import { windowsToGoldenCases, caseIdHash } from "./to_golden.ts";
import {
  aggregateBenchmark,
  buildReconciliationFixed,
  evergreenAssessment,
  scoreStage2Historical,
  stage2SanitizedViolations,
} from "./score_stage2.ts";
import type { Stage2HistoricalReport } from "./types.ts";
import { STAGE2_SCHEMA_VERSION } from "./types.ts";

function assertCertDatabaseSafe(): void {
  validateCertDatabaseTarget(undefined);
}

function parseFlags(argv: string[]): { ingestOnly: boolean; corpusPath?: string } {
  let ingestOnly = false;
  const positional: string[] = [];
  for (const arg of argv) {
    if (arg === "--ingest-only") ingestOnly = true;
    else if (arg === "--help" || arg === "-h") {
      console.error(
        "Usage: run.ts [--ingest-only] [WA_PROTECTED_CORPUS_PATH]\n" +
          "  Accepts raw WhatsApp .txt or .zip (_chat.txt inside).\n" +
          "  --ingest-only parses/segments/labels without Core DB evaluation.",
      );
      Deno.exit(0);
    } else positional.push(arg);
  }
  return {
    ingestOnly,
    corpusPath: positional[0] ?? Deno.env.get("WA_PROTECTED_CORPUS_PATH") ?? undefined,
  };
}

async function writeIngestOnlyReport(
  ingest: Awaited<ReturnType<typeof ingestHistoricalCorpus>>,
  windows: ReturnType<typeof buildCertificationWindows>,
): Promise<Stage2HistoricalReport> {
  const expectedDist = distributionByClass(windows);
  const evergreenWindows = windows.filter((w) => w.evergreen_cluster_id != null);
  return {
    schema_version: STAGE2_SCHEMA_VERSION,
    status: "BLOCKED",
    final_verdict: "BLOCKED",
    declaration: "STAGE 2 HISTORICAL CORPUS — INGEST COMPLETE; AWAITING CORE DB EVALUATION",
    blocker: "Core evaluation requires loopback cert DATABASE_URL (local supabase on :54322). Production refs forbidden.",
    core_sha: await gitSha("HEAD"),
    corpus_hash: ingest.corpus_hash,
    corpus_bytes: ingest.corpus_bytes,
    parsed_message_count: ingest.messages.length,
    certification_window_count: windows.length,
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
    reconciliation: buildReconciliationFixed(
      ingest.messages.filter((m) => !m.is_system).length,
      windows,
      ingest.messages.filter((m) => m.is_system).length,
      0,
    ),
    evergreen_subset: {
      cluster_count: new Set(evergreenWindows.map((w) => w.evergreen_cluster_id)).size,
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

const ARTIFACT_DIR = "artifacts/wa-stage2-historical";
const REPORT_PATH = `${ARTIFACT_DIR}/report.json`;
const BENCHMARK_THRESHOLD = 0.95;

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

async function writeReport(report: Stage2HistoricalReport): Promise<void> {
  await Deno.mkdir(ARTIFACT_DIR, { recursive: true });
  await Deno.writeTextFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`);
}

function blockedReport(blocker: string): Stage2HistoricalReport {
  return {
    schema_version: STAGE2_SCHEMA_VERSION,
    status: "BLOCKED",
    final_verdict: "BLOCKED",
    declaration: "STAGE 2 HISTORICAL CORPUS — BLOCKED ON OWNER-PROVIDED CORPUS",
    blocker,
    corpus_bytes: 0,
    parsed_message_count: 0,
    certification_window_count: 0,
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

/** Bump when Stage 2 interpretation stub semantics change (isolates cert entity IDs). */
const STAGE2_STUB_GENERATION = "20260831-v2";

async function runHistoricalCases(
  cases: Awaited<ReturnType<typeof windowsToGoldenCases>>,
  corpusHash: string,
): Promise<{
  observed: import("../whatsapp-autonomy-eval/types.ts").ObservedResult[];
  replayViolations: string[];
  executedCount: number;
  totalCases: number;
}> {
  const effectiveCorpusHash = `${corpusHash}:${STAGE2_STUB_GENERATION}`;
  const {
    connectCertDatabase,
    executeGoldenCase,
    resetCertWhatsAppHarness,
    seedCertMasterData,
    setServiceRoleForHarness,
  } = await import("../whatsapp-autonomy-eval/core_runner.ts");
  const maxCases = Number(Deno.env.get("WA_STAGE2_MAX_CASES") ?? "0");
  const slice = maxCases > 0 ? cases.slice(0, maxCases) : cases;
  const sql = connectCertDatabase();
  const observed: import("../whatsapp-autonomy-eval/types.ts").ObservedResult[] = [];
  const replayViolations: string[] = [];
  try {
    await setServiceRoleForHarness(sql);
    await resetCertWhatsAppHarness(sql);
    await seedCertMasterData(sql);
    for (const [index, testCase] of slice.entries()) {
      observed.push(await executeGoldenCase(sql, testCase, index + 1, "protected", effectiveCorpusHash));
    }
    for (const [index, testCase] of slice.entries()) {
      if (!testCase.replay_twice) continue;
      const replay = await executeGoldenCase(sql, testCase, index + 1, "protected", effectiveCorpusHash);
      if (!replay.idempotent_replay) {
        const hash = await caseIdHash(testCase.id, corpusHash);
        replayViolations.push(`${hash}: correction/amendment replay not idempotent`);
      }
    }
  } finally {
    await resetCertWhatsAppHarness(sql);
    await sql.end({ timeout: 5 });
  }
  return {
    observed,
    replayViolations,
    executedCount: slice.length,
    totalCases: cases.length,
  };
}

function safeSummary(report: Stage2HistoricalReport): Record<string, unknown> {
  return {
    declaration: report.declaration,
    final_verdict: report.final_verdict,
    status: report.status,
    blocker: report.blocker,
    corpus_hash: report.corpus_hash,
    corpus_bytes: report.corpus_bytes,
    parsed_message_count: report.parsed_message_count,
    certification_window_count: report.certification_window_count,
    aggregate_governed_benchmark: report.aggregate_governed_benchmark,
    zero_tolerance: report.zero_tolerance,
    reconciliation: report.reconciliation,
    evergreen_subset: report.evergreen_subset,
    defects_found_count: report.defects_found.length,
    violations_count: report.violations.length,
  };
}

if (import.meta.main) {
  const { ingestOnly, corpusPath } = parseFlags(Deno.args);

  try {
    const ingest = await ingestHistoricalCorpus(corpusPath);
    const businessMessages = ingest.messages.filter((m) => !m.is_system);
    const systemExcluded = ingest.messages.filter((m) => m.is_system).length;
    const windows = buildCertificationWindows(ingest.messages);

    if (ingestOnly) {
      const report = await writeIngestOnlyReport(ingest, windows);
      await writeReport(report);
      console.log(JSON.stringify({ ingest: summarizeIngest(ingest), windows: windows.length, mode: "ingest-only" }, null, 2));
      Deno.exit(0);
    }

    assertCertDatabaseSafe();
    const deletedOnly = ingest.messages.filter((m) => m.is_deleted && !m.is_system).length;

    const goldenCases = await windowsToGoldenCases(
      windows,
      ingest.messages,
      ingest.corpus_hash,
    );

    const scored = await runHistoricalCases(goldenCases, ingest.corpus_hash);
    const stage2Score = scoreStage2Historical(windows, goldenCases, scored.observed);

    const benchmark = aggregateBenchmark(
      stage2Score.routing_match_rate,
      stage2Score.coreReport,
    );
    const zeroSum = Object.values(stage2Score.zero_tolerance).reduce((a, b) => a + b, 0);
    const passBenchmark = benchmark >= BENCHMARK_THRESHOLD &&
      stage2Score.defects.length === 0;
    const passZero = zeroSum === 0 &&
      stage2Score.coreReport.dangerous_false_positives.length === 0;
    const reconciliation = buildReconciliationFixed(
      businessMessages.length,
      windows,
      systemExcluded,
      deletedOnly,
    );
    const passReconciliation = reconciliation.balanced && reconciliation.unaccounted === 0;
    const sanitizedViolations = [
      ...stage2SanitizedViolations(stage2Score.coreReport),
      ...scored.replayViolations,
    ];
    const partialRun = scored.executedCount < goldenCases.length;
    const pass = passBenchmark && passZero && passReconciliation &&
      sanitizedViolations.length === 0 && !partialRun;

    const evergreen = evergreenAssessment(windows, stage2Score.defects);
    const expectedDist = distributionByClass(windows);
    const trafficDist = goldenCases.reduce<Record<string, number>>((acc, c) => {
      acc[c.traffic_class] = (acc[c.traffic_class] ?? 0) + 1;
      return acc;
    }, {});

    const remainingAmbiguity = Object.fromEntries(
      Object.entries(stage2Score.per_category_scores)
        .filter(([key]) => key.includes("AMBIGUOUS") || key.includes("MEDIA_UNAVAILABLE"))
        .map(([key, val]) => [key, val.count]),
    );

    const report: Stage2HistoricalReport = {
      schema_version: STAGE2_SCHEMA_VERSION,
      status: pass ? "COMPLETE" : "FAILED",
      final_verdict: pass ? "PASS" : "FAIL",
      declaration: pass
        ? "STAGE 2 HISTORICAL CORPUS CERTIFICATION — PASS"
        : "STAGE 2 HISTORICAL CORPUS CERTIFICATION — FAIL",
      core_sha: await gitSha("HEAD"),
      corpus_hash: ingest.corpus_hash,
      corpus_bytes: ingest.corpus_bytes,
      parsed_message_count: ingest.messages.length,
      certification_window_count: windows.length,
      category_distribution: trafficDist,
      expected_class_distribution: expectedDist as Record<string, number>,
      historical_date_range: ingest.date_range,
      unique_senders: ingest.unique_senders,
      commercial_party_contexts: ingest.commercial_party_contexts,
      aggregate_governed_benchmark: benchmark,
      per_category_scores: stage2Score.per_category_scores,
      field_accuracy: {
        order_detection: stage2Score.per_category_scores["ORDER"]?.match_rate ?? null,
        non_order_detection:
          stage2Score.per_category_scores["NON_ORDER_BUSINESS"]?.match_rate ?? null,
        sender_customer_linkage: stage2Score.coreReport.customer_accuracy,
        intent: stage2Score.routing_match_rate,
        stitching: null,
        product_extraction: stage2Score.coreReport.sku_accuracy,
        quantity_extraction: stage2Score.coreReport.quantity_accuracy,
        uom: stage2Score.coreReport.uom_accuracy,
        amendments: stage2Score.per_category_scores["ORDER_AMENDMENT"]?.match_rate ?? null,
        cancellations: stage2Score.per_category_scores["ORDER_CANCELLATION"]?.match_rate ?? null,
        dedup: null,
        complaints: stage2Score.per_category_scores["COMPLAINT"]?.match_rate ?? null,
        payments: stage2Score.per_category_scores["PAYMENT_PROOF"]?.match_rate ?? null,
        dispatch: stage2Score.per_category_scores["DISPATCH_REQUEST"]?.match_rate ?? null,
        clarification: stage2Score.coreReport.clarification_rate,
        mixed_intent: null,
        media_unavailable: stage2Score.per_category_scores["MEDIA_UNAVAILABLE"]?.match_rate ?? null,
        reconciliation: passReconciliation ? 1 : 0,
      },
      zero_tolerance: stage2Score.zero_tolerance,
      dangerous_failure_counters: {
        dangerous_false_positives: stage2Score.coreReport.dangerous_false_positives.length,
        false_orders: stage2Score.coreReport.false_orders.length,
        outcome_mismatches: stage2Score.coreReport.outcome_mismatches.length,
      },
      reconciliation,
      evergreen_subset: evergreen,
      defects_found: stage2Score.defects.slice(0, 100).map((d) => ({
        case_id: d.case_id.split("-").slice(-2).join("-"),
        expected: d.expected,
        actual: d.actual,
        root_cause: d.root_cause.slice(0, 200),
      })),
      defects_fixed: [],
      remaining_ambiguity_categories: remainingAmbiguity,
      excluded_cases: partialRun
        ? [`partial-run: executed ${scored.executedCount}/${goldenCases.length} windows`]
        : [],
      violations: sanitizedViolations,
      stage1b_regression: {
        status: "NOT_RERUN",
        note: "Stage 1B closed PASS on b7635232; rerun only if runtime layers change materially",
      },
    };

    await writeReport(report);
    console.log(JSON.stringify({ ingest: summarizeIngest(ingest), result: safeSummary(report) }, null, 2));
    Deno.exit(pass ? 0 : 1);
  } catch (error) {
    const blocker = error instanceof Error ? error.message : String(error);
    const report = blockedReport(blocker);
    report.core_sha = await gitSha("HEAD");
    await writeReport(report);
    console.error(JSON.stringify(safeSummary(report), null, 2));
    Deno.exit(2);
  }
}
