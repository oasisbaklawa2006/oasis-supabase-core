/** @file Stage-1B preview certification engine — NON-PRODUCTION only. */

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import manifest from "./fixtures_manifest.json" with { type: "json" };
import {
  CERT_RUNNER_VERSION,
  PREVIEW_CERT_PROJECT_REF,
  REPORT_SCHEMA_VERSION,
  type Fixture,
  type FixtureResult,
  type GateResult,
  type HarnessReport,
} from "./constants.ts";
import { assertPreviewCertRuntime } from "./previewPin.ts";
import {
  buildMetrics,
  isImageOnlyFixture,
  recognitionFrom,
  scoreFixture,
} from "./scoring.ts";
import {
  assertNoOutstandingBacklog,
  loadPersistedOutcome,
  reconciliation,
  reconcilePriorRetryJobs,
  seedPacket,
} from "./db.ts";
import { seedCertMasterData } from "./seed.ts";
import {
  ensurePublicBucket,
  invokeClaimedWorker,
  probeWorkerRuntime,
  runtimeSecretReadiness,
  uploadFixtureBytes,
  type FixtureFileInput,
} from "./worker.ts";
import {
  evaluateGateA,
  evaluateGateB,
  evaluateGateC,
  evaluateGateD,
  evaluateGateE,
  finalVerdict,
} from "./gates.ts";

export type CertRunRequest = {
  run_id?: string;
  core_sha?: string;
  cert_branch_sha?: string;
  fixtures: Array<{
    id: string;
    media_type: string;
    caption?: string | null;
    follow_up_text?: string;
    ground_truth: Record<string, unknown>;
    files: FixtureFileInput[];
  }>;
};

function manifestFixture(id: string): Fixture | undefined {
  return (manifest.fixtures as Fixture[]).find((f) => f.id === id);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.slice(0, 2000) : String(error).slice(0, 2000);
}

export async function runStage1bPreviewCert(
  request: CertRunRequest,
): Promise<HarnessReport> {
  const { supabaseUrl, projectRef } = assertPreviewCertRuntime();
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!serviceRoleKey) throw new Error("PREVIEW_PIN_FAILED:SUPABASE_SERVICE_ROLE_KEY_MISSING");

  const runId = request.run_id ?? crypto.randomUUID();
  const runTag = runId.replace(/[^0-9a-f]/gi, "").toLowerCase().slice(0, 12);
  const readiness = runtimeSecretReadiness();

  const report: HarnessReport = {
    schema_version: REPORT_SCHEMA_VERSION,
    status: "BLOCKED",
    preview_project_ref: projectRef,
    cert_runner_version: CERT_RUNNER_VERSION,
    run_id: runId,
    core_sha: request.core_sha,
    cert_branch_sha: request.cert_branch_sha,
    runtime_secret_readiness: readiness,
    fixture_count: 0,
    image_only_count: 0,
    pdf_count: 0,
    audio_count: 0,
    video_count: 0,
    worker_invocations: 0,
    dangerous_media_false_positives: 0,
    invented_commercial_leakage: 0,
    silent_media_loss: 0,
    gates: [],
    results: [],
  };

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const packetIds: string[] = [];
  let gateCEvidence: Record<string, unknown> = {};

  try {
    const runtime = await probeWorkerRuntime(supabaseUrl, serviceRoleKey);
    report.runtime_secret_readiness.GEMINI_API_KEY_EDGE_RUNTIME = runtime.configured;
    if (!runtime.configured) {
      throw new Error("MISSING_CERT_EDGE_RUNTIME_SECRET:GEMINI_API_KEY");
    }

    const mandatoryIds = (manifest.fixtures as Fixture[])
      .filter((f) => !f.optional)
      .map((f) => f.id);
    const submittedIds = new Set(request.fixtures.map((f) => f.id));
    const missingMandatory = mandatoryIds.filter((id) => !submittedIds.has(id));
    if (missingMandatory.length) {
      throw new Error(`MANDATORY_FIXTURE_UNAVAILABLE:${missingMandatory.join(",")}`);
    }

    const fixtures: Fixture[] = request.fixtures.map((input) => {
      const base = manifestFixture(input.id);
      if (!base) throw new Error(`UNKNOWN_FIXTURE:${input.id}`);
      return {
        ...base,
        caption: input.caption ?? base.caption,
        follow_up_text: input.follow_up_text ?? base.follow_up_text,
        ground_truth: input.ground_truth ?? base.ground_truth,
      };
    });

    report.fixture_count = fixtures.length;
    report.image_only_count = fixtures.filter(isImageOnlyFixture).length;
    report.pdf_count = fixtures.filter((f) => f.media_type === "document").length;
    report.audio_count = fixtures.filter((f) => f.media_type === "audio").length;
    report.video_count = fixtures.filter((f) => f.media_type === "video").length;

    await seedCertMasterData(admin);
    await reconcilePriorRetryJobs(admin);
    await assertNoOutstandingBacklog(admin);
    await ensurePublicBucket(admin);

    for (const [index, fixture] of fixtures.entries()) {
      const input = request.fixtures.find((f) => f.id === fixture.id)!;
      const mediaUrls: string[] = [];
      for (const file of input.files) {
        mediaUrls.push(
          await uploadFixtureBytes(admin, supabaseUrl, runTag, file),
        );
      }

      const { packetId, providerIds } = await seedPacket(
        admin,
        fixture,
        index,
        mediaUrls,
        runId,
        runTag,
      );
      packetIds.push(packetId);

      const workerResult = await invokeClaimedWorker(
        supabaseUrl,
        serviceRoleKey,
        packetId,
      );
      report.worker_invocations += 1;

      const persisted = await loadPersistedOutcome(admin, packetId);
      const recognition = recognitionFrom(persisted.interpretation);
      const scores = scoreFixture(fixture, persisted);

      if (scores.dangerous_false_positive) report.dangerous_media_false_positives += 1;
      if (scores.invented_commercial_leakage) report.invented_commercial_leakage += 1;
      if (!persisted.interpretation_id && fixture.media_type !== "text") {
        report.silent_media_loss += 1;
      }

      report.results.push({
        fixture_id: fixture.id,
        packet_id: packetId,
        provider_message_ids: providerIds,
        worker: workerResult,
        ground_truth: fixture.ground_truth,
        persisted,
        recognition,
        scores,
      });
    }

    report.metrics = buildMetrics(report.results, fixtures);
    report.reconciliation = await reconciliation(admin, runTag, packetIds);

    const mandatoryCount = mandatoryIds.length;
    report.gates.push(
      evaluateGateA(
        report.results,
        mandatoryCount,
        report.dangerous_media_false_positives,
        report.invented_commercial_leakage,
      ),
    );

    report.gates.push(
      await evaluateGateB(
        admin,
        supabaseUrl,
        serviceRoleKey,
        report.results,
        runId,
        runTag,
      ),
    );

    const gateCFixture = fixtures.find((f) => f.id === "01-printed-order") ?? fixtures[0];
    const gateCInput = request.fixtures.find((f) => f.id === gateCFixture.id)!;
    const gateCMedia = await uploadFixtureBytes(
      admin,
      supabaseUrl,
      `${runTag}-gatec`,
      gateCInput.files[0],
    );
    const gateC = await evaluateGateC(
      admin,
      supabaseUrl,
      serviceRoleKey,
      runId,
      runTag,
      gateCFixture,
      gateCMedia,
    );
    report.gates.push(gateC.gate);
    gateCEvidence = gateC.evidence;

    report.gates.push(evaluateGateD(report.results));
    report.reconciliation = await reconciliation(admin, runTag, packetIds);
    report.gates.push(evaluateGateE(report));

    report.adversarial = gateCEvidence;
    report.final_verdict = finalVerdict(report.gates);
    report.status = report.final_verdict === "PASS" ? "COMPLETE" : "FAILED";
    if (report.status !== "COMPLETE") {
      report.blocker = report.gates.find((g) => g.status === "FAIL")?.detail ??
        "STAGE1B_GATE_FAILED";
    }
  } catch (error) {
    report.blocker = errorMessage(error);
    report.status = report.worker_invocations > 0 || report.results.length > 0
      ? "FAILED"
      : "BLOCKED";
    report.final_verdict = "FAIL";
    if (packetIds.length) {
      try {
        report.reconciliation = await reconciliation(admin, runTag, packetIds);
      } catch (reconError) {
        report.blocker = `${report.blocker};PARTIAL_RECON_FAILED:${errorMessage(reconError)}`;
      }
    }
  }

  return report;
}
