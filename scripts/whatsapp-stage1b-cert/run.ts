/**
 * Stage-1B controlled multimodal worker certification orchestrator.
 * Generates synthetic fixtures locally, invokes the preview-only cert runner Edge
 * Function on jyezfiehhfgnvhzzffxr in phased calls to stay within edge idle limits.
 */
import manifest from "./fixtures_manifest.json" with { type: "json" };
import { assertOrchestratorPreviewUrl } from "../../supabase/functions/_shared/stage1bCert/previewPin.ts";
import { resolvePreviewCertBearerToken } from "../../supabase/functions/_shared/stage1bCert/previewCertAuth.ts";
import { PREVIEW_CERT_PROJECT_REF } from "../../supabase/functions/_shared/stage1bCert/constants.ts";

const PREVIEW_SUPABASE_URL = `https://${PREVIEW_CERT_PROJECT_REF}.supabase.co`;
const ARTIFACT_DIR = "artifacts/wa-stage1b-cert";
const FIXTURE_ROOT = Deno.env.get("WA_STAGE1B_FIXTURE_ROOT") ??
  "/tmp/wa-stage1b-cert-fixtures";
const PHASE_TIMEOUT_MS = 140 * 1000;

type Fixture = {
  id: string;
  file?: string;
  files?: string[];
  media_type: string;
  caption?: string | null;
  follow_up_text?: string;
  optional?: boolean;
  ground_truth: Record<string, unknown>;
};

type HarnessReport = {
  schema_version: string;
  status: string;
  final_verdict?: string;
  [key: string]: unknown;
};

type FixtureResult = {
  fixture_id: string;
  packet_id: string;
  [key: string]: unknown;
};

function toBase64(path: string): string {
  const bytes = Deno.readFileSync(path);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function gitSha(ref: string): Promise<string | undefined> {
  try {
    const out = new Deno.Command("git", {
      args: ["rev-parse", ref],
      stdout: "piped",
      stderr: "piped",
    });
    const result = await out.output();
    if (!result.success) return undefined;
    return new TextDecoder().decode(result.stdout).trim();
  } catch {
    return undefined;
  }
}

async function generateFixtures(): Promise<
  { generated: string[]; skipped: string[] }
> {
  const env: Record<string, string> = { WA_STAGE1B_FIXTURE_ROOT: FIXTURE_ROOT };
  for (
    const name of [
      "WA_STAGE1B_AUDIO_FIXTURE",
      "WA_STAGE1B_DEVANAGARI_FONT",
      "WA_STAGE1B_HANDWRITTEN_FIXTURE",
    ]
  ) {
    const value = Deno.env.get(name);
    if (value) env[name] = value;
  }
  const gen = new Deno.Command("python3", {
    args: [new URL("./generate_fixtures.py", import.meta.url).pathname],
    env,
    stdout: "piped",
    stderr: "piped",
  });
  const output = await gen.output();
  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
  if (!output.success) {
    throw new Error(
      `FIXTURE_GENERATION_FAILED:code=${output.code}:stdout=${
        stdout.slice(-1000)
      }:stderr=${stderr.slice(-1000)}`,
    );
  }
  return JSON.parse(stdout) as { generated: string[]; skipped: string[] };
}

async function writeReport(report: HarnessReport): Promise<void> {
  await Deno.mkdir(ARTIFACT_DIR, { recursive: true });
  await Deno.writeTextFile(
    `${ARTIFACT_DIR}/report.json`,
    `${JSON.stringify(report, null, 2)}\n`,
  );
}

function fixturePayload(fixture: Fixture) {
  const names = fixture.files ?? (fixture.file ? [fixture.file] : []);
  return {
    id: fixture.id,
    media_type: fixture.media_type,
    caption: fixture.caption ?? null,
    follow_up_text: fixture.follow_up_text,
    ground_truth: fixture.ground_truth,
    files: names.map((name) => ({
      name,
      base64: toBase64(`${FIXTURE_ROOT}/${name}`),
    })),
  };
}

function phaseTimeoutSignal(ms: number): AbortSignal {
  if (typeof AbortSignal.timeout === "function") {
    return AbortSignal.timeout(ms);
  }
  const controller = new AbortController();
  setTimeout(() => controller.abort(), ms);
  return controller.signal;
}

function classifyRunnerTransportError(error: unknown): string {
  if (error instanceof DOMException && error.name === "TimeoutError") {
    return "RUNNER_TIMEOUT";
  }
  if (error instanceof Error && error.name === "AbortError") {
    return "RUNNER_TIMEOUT";
  }
  return "RUNNER_TRANSPORT_FAILED";
}

async function callRunner(
  previewUrl: string,
  certSecret: string,
  payload: Record<string, unknown>,
): Promise<{ ok: boolean; status: number; body: Record<string, unknown> }> {
  const runnerUrl = `${
    previewUrl.replace(/\/$/, "")
  }/functions/v1/whatsapp-stage1b-cert-runner`;
  try {
    const response = await fetch(runnerUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${certSecret}`,
        "Content-Type": "application/json",
        "X-WA-Cert-Preview-Url": previewUrl,
      },
      body: JSON.stringify(payload),
      signal: phaseTimeoutSignal(PHASE_TIMEOUT_MS),
    });
    let body: Record<string, unknown>;
    try {
      body = await response.json() as Record<string, unknown>;
    } catch {
      return {
        ok: false,
        status: response.status,
        body: { error: "RUNNER_JSON_DECODE_FAILED" },
      };
    }
    return { ok: response.ok, status: response.status, body };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      body: { error: classifyRunnerTransportError(error) },
    };
  }
}

async function writeFailClosedReport(
  blocker: string,
  partial: Partial<HarnessReport> = {},
): Promise<never> {
  const report: HarnessReport = {
    schema_version: "wa-stage1b-report/v3",
    status: "FAILED",
    final_verdict: "FAIL",
    blocker,
    preview_project_ref: PREVIEW_CERT_PROJECT_REF,
    run_id: Deno.env.get("WA_STAGE1B_RUN_ID") ?? crypto.randomUUID(),
    ...partial,
  };
  await writeReport(report);
  console.error(JSON.stringify(report, null, 2));
  Deno.exit(2);
}

async function main(): Promise<void> {
  const envUrl = Deno.env.get("SUPABASE_URL");
  const previewUrl = envUrl && !envUrl.includes("api.oasisbaklawa")
    ? envUrl
    : PREVIEW_SUPABASE_URL;
  assertOrchestratorPreviewUrl(previewUrl);

  const certSecret = await resolvePreviewCertBearerToken();
  const runId = Deno.env.get("WA_STAGE1B_RUN_ID") ?? crypto.randomUUID();
  const coreSha = await gitSha("origin/main");
  const certBranchSha = await gitSha("origin/cert/wa-release-cert");

  const generated = await generateFixtures();
  const generatedSet = new Set(generated.generated);
  const fixtures = (manifest.fixtures as Fixture[]).filter((fixture) => {
    const names = fixture.files ?? (fixture.file ? [fixture.file] : []);
    return names.every((name) => generatedSet.has(name));
  });
  const missingMandatory = (manifest.fixtures as Fixture[]).filter(
    (fixture) => {
      if (fixture.optional) return false;
      const names = fixture.files ?? (fixture.file ? [fixture.file] : []);
      return names.some((name) => !generatedSet.has(name));
    },
  );
  if (missingMandatory.length) {
    throw new Error(
      `MANDATORY_FIXTURE_UNAVAILABLE:${
        missingMandatory.map((f) => f.id).join(",")
      }`,
    );
  }

  const setup = await callRunner(previewUrl, certSecret, {
    phase: "setup",
    run_id: runId,
    core_sha: coreSha,
    cert_branch_sha: certBranchSha,
  });
  if (!setup.ok) {
    const report: HarnessReport = {
      schema_version: "wa-stage1b-report/v3",
      status: "BLOCKED",
      final_verdict: "FAIL",
      blocker: String(setup.body.error ?? `SETUP_HTTP_${setup.status}`),
      preview_project_ref: PREVIEW_CERT_PROJECT_REF,
      run_id: runId,
    };
    await writeReport(report);
    console.error(JSON.stringify(report, null, 2));
    Deno.exit(2);
  }

  const runTag = String(setup.body.run_tag ?? "");
  const results: FixtureResult[] = [];
  const packetIds: string[] = [];

  for (const [index, fixture] of fixtures.entries()) {
    console.error(
      `Scoring fixture ${index + 1}/${fixtures.length}: ${fixture.id}`,
    );
    const scored = await callRunner(previewUrl, certSecret, {
      phase: "fixture",
      run_id: runId,
      run_tag: runTag,
      fixture_index: index,
      fixture: fixturePayload(fixture),
      core_sha: coreSha,
      cert_branch_sha: certBranchSha,
    });
    if (!scored.ok) {
      const report: HarnessReport = {
        schema_version: "wa-stage1b-report/v3",
        status: "FAILED",
        final_verdict: "FAIL",
        blocker: `FIXTURE_${fixture.id}_HTTP_${scored.status}:${
          String(scored.body.error ?? "")
        }`,
        preview_project_ref: PREVIEW_CERT_PROJECT_REF,
        run_id: runId,
        results,
        worker_invocations: results.length,
      };
      await writeReport(report);
      console.error(JSON.stringify(report, null, 2));
      Deno.exit(2);
    }
    const result = scored.body.result as FixtureResult;
    results.push(result);
    packetIds.push(result.packet_id);
  }

  const gateCFixture = fixtures.find((f) => f.id === "01-printed-order") ??
    fixtures[0];
  const gates = await callRunner(previewUrl, certSecret, {
    phase: "gates",
    run_id: runId,
    run_tag: runTag,
    accumulated_results: results,
    packet_ids: packetIds,
    gate_c_fixture: fixturePayload(gateCFixture),
    core_sha: coreSha,
    cert_branch_sha: certBranchSha,
  });

  const report = (gates.body.report as HarnessReport | undefined) ?? {
    schema_version: "wa-stage1b-report/v3",
    status: "BLOCKED",
    final_verdict: "FAIL",
    blocker: String(gates.body.error ?? `GATES_HTTP_${gates.status}`),
    preview_project_ref: PREVIEW_CERT_PROJECT_REF,
    run_id: runId,
    results,
  };

  await writeReport(report);

  if (report.final_verdict === "PASS" && report.status === "COMPLETE") {
    console.log("STAGE 1B MEDIA CERTIFICATION — PASS");
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.error(JSON.stringify(report, null, 2));
  Deno.exit(2);
}

if (import.meta.main) {
  try {
    await main();
  } catch (error) {
    await writeFailClosedReport(
      error instanceof Error ? error.message : String(error),
    );
  }
}
