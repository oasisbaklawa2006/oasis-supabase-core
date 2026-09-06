/**
 * Historical media-inclusive certification orchestrator (PR #203).
 */
import { validateCertDatabaseTarget } from "../whatsapp-autonomy-eval/database_target.ts";
import { parseWhatsAppExport } from "../whatsapp-stage2-historical/parse_export.ts";
import { runMediaAuthorityReconciliation } from "../whatsapp-stage2-historical/media_authority_reconciliation.ts";
import { extractChatTextFromZip } from "./media_pairing_io.ts";
import { verifyProtectedCorpusGate, CERTIFIED_TEXT_HASH, MEDIA_SIDECAR_HASH } from "./protected_corpus_gate.ts";
import { buildPairedMediaPopulation } from "./ground_truth.ts";
import { countByModality, countImageSubtypes } from "./media_inventory.ts";
import { selectExecutionSample } from "./sampler.ts";
import {
  createLocalAdmin,
  ensureHistMediaBucket,
  HIST_MEDIA_BUCKET,
} from "./media_storage.ts";
import {
  executeHistoricalMediaCase,
  prepareHistMediaCertRuntime,
  replayHistoricalMediaCase,
} from "./media_runner.ts";
import {
  aggregateMetrics,
  aggregateZeroTolerance,
  classifyFailures,
  scoreHistoricalMediaCase,
} from "./score.ts";
import {
  buildHistoricalMediaReport,
  passVerdict,
  sanitizeCaseResults,
} from "./report_builder.ts";
import type { MediaCaseResult } from "./types.ts";
import { reconciliation } from "../../supabase/functions/_shared/stage1bCert/db.ts";

const ARTIFACT_PATH = "artifacts/wa-historical-media/report.json";

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

async function writeReport(report: ReturnType<typeof buildHistoricalMediaReport>): Promise<void> {
  await Deno.mkdir("artifacts/wa-historical-media", { recursive: true });
  await Deno.writeTextFile(ARTIFACT_PATH, `${JSON.stringify(report, null, 2)}\n`);
}

async function extractMediaChat(mediaZip: string): Promise<string> {
  return await extractChatTextFromZip(mediaZip);
}

async function main(): Promise<void> {
  const startingSha = await gitSha("HEAD");
  const mainSha = await gitSha("origin/main");

  const gate = await verifyProtectedCorpusGate();
  if (gate.status !== "READY") {
    console.error(gate.verdict);
    Deno.exit(1);
  }

  validateCertDatabaseTarget(undefined);
  Deno.env.set("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP", "true");

  const pairing = await runMediaAuthorityReconciliation();
  if (pairing.final_verdict !== "PASS") {
    throw new Error(`PAIRING_PREFLIGHT_FAILED:${pairing.fail_reason ?? "unknown"}`);
  }

  const mediaZip = gate.paths.mediaZip;
  const mediaRaw = await extractMediaChat(mediaZip);
  const messages = parseWhatsAppExport(mediaRaw);
  const population = await buildPairedMediaPopulation(mediaZip, messages);

  const modalityInventory = countByModality(
    population.filter((p) => p.archive_entry).map((p) => ({ modality: p.modality })),
  );
  const imageSubtypeCounts = countImageSubtypes(population);

  const maxCases = Number(Deno.env.get("WA_HIST_MEDIA_MAX_CASES") ?? "96");
  const sampleSeed = Deno.env.get("WA_HIST_MEDIA_SAMPLE_SEED") ?? "wa-hist-media-v1";
  const { selected, rule } = selectExecutionSample(population, maxCases, sampleSeed);
  const eligibleCount = population.filter((p) => p.eligible).length;
  const imageOnlyCases = population.filter((p) =>
    p.eligible && p.image_subtype === "IMAGE_ONLY"
  ).length;

  const { admin, supabaseUrl } = createLocalAdmin();
  await ensureHistMediaBucket(admin);
  await prepareHistMediaCertRuntime(admin);

  const runTag = `${(await gitSha("HEAD")).slice(0, 8)}-${crypto.randomUUID().slice(0, 8)}`;
  const results: MediaCaseResult[] = [];
  const packetIds: string[] = [];
  let replayPass = true;
  let correctionPass = true;

  for (const [caseIndex, ref] of selected.entries()) {
    try {
      const execution = await executeHistoricalMediaCase(
        admin,
        supabaseUrl,
        mediaZip,
        ref,
        runTag,
        caseIndex + 1,
      );
      packetIds.push(execution.packetId);
      const scored = scoreHistoricalMediaCase(
        ref,
        execution.persisted,
        "OK",
        null,
      );
      scored.packet_id = execution.packetId;
      results.push(scored);

      const replay = await replayHistoricalMediaCase(admin, execution.packetId);
      const replayPromoted = Boolean(
        (replay.communication_case as Record<string, unknown> | undefined)?.draft_execution,
      );
      const idempotent = !scored.scores.auto_actioned || !replayPromoted;
      scored.replay_idempotent = idempotent;
      if (!idempotent) replayPass = false;

      if (ref.stratum.includes("MEDIA_WITH_CORRECTION") && !scored.scores.clarification_correct) {
        correctionPass = false;
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      results.push({
        case_id: ref.case_id,
        message_index: ref.message_index,
        modality: ref.modality,
        image_subtype: ref.image_subtype,
        stratum: ref.stratum,
        packet_id: null,
        worker_status: message.slice(0, 200),
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
        failure_class: message.includes("GEMINI") || message.includes("WORKER")
          ? "PROVIDER_LIMITATION"
          : message.includes("TOO_LARGE")
          ? "MEDIA_QUALITY_LIMITATION"
          : "HARNESS_DEFECT",
        replay_idempotent: null,
      });
    }
  }

  const metrics = aggregateMetrics(results);
  const zeroTolerance = aggregateZeroTolerance(results);
  const failureClassification = classifyFailures(results);
  const recon = await reconciliation(admin, runTag, packetIds);
  const reconciliationBalanced = (recon.orphan_raw_messages ?? 0) === 0 &&
    (recon.packets_without_case ?? 0) === 0 &&
    (recon.duplicate_promoted_orders ?? 0) === 0;

  const successfulInterpretations = results.filter((r) =>
    r.persisted.interpretation != null
  ).length;
  const finalVerdict = passVerdict(
    zeroTolerance,
    reconciliationBalanced,
    successfulInterpretations,
    results.length,
  );
  const mediaArchiveBytes = Number(
    Deno.statSync(mediaZip).size,
  );

  const report = buildHistoricalMediaReport({
    status: "COMPLETE",
    final_verdict: finalVerdict,
    starting_core_sha: startingSha,
    final_head_sha: await gitSha("HEAD"),
    text_authority_hash: CERTIFIED_TEXT_HASH,
    media_sidecar_hash: MEDIA_SIDECAR_HASH,
    media_archive_bytes: mediaArchiveBytes,
    protected_corpus_gate: "READY",
    pairing_preflight: "PASS",
    total_media_references: pairing.media_references,
    paired_references: pairing.successfully_paired_media_references,
    unpaired_detections: pairing.unpaired_media_references,
    media_by_type: modalityInventory,
    image_subtype_counts: imageSubtypeCounts,
    eligible_media_cases: eligibleCount,
    executed_media_cases: results.length,
    coverage_percentage: eligibleCount
      ? results.length / eligibleCount
      : null,
    sampling_rule: rule,
    image_only_cases: imageOnlyCases,
    metrics,
    zero_tolerance_counters: zeroTolerance,
    correction_continuation_result: correctionPass ? "PASS" : "FAIL",
    replay_result: replayPass ? "PASS" : "FAIL",
    reconciliation_result: reconciliationBalanced ? "BALANCED" : "UNBALANCED",
    failure_classification: failureClassification,
    production_supabase_mutated: false,
    raw_corpus_in_git: false,
    case_results: sanitizeCaseResults(results),
    reconciliation: recon,
    current_main_sha: mainSha,
  });

  await writeReport(report);

  console.log(JSON.stringify({
    final_verdict: report.final_verdict,
    executed: report.executed_media_cases,
    eligible: report.eligible_media_cases,
    coverage: report.coverage_percentage,
    zero_tolerance: report.zero_tolerance_counters,
    metrics: report.metrics,
  }, null, 2));

  if (finalVerdict !== "PASS") Deno.exit(2);
}

if (import.meta.main) {
  await main();
}
