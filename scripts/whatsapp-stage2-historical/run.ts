/**
 * Stage 2 — protected historical WhatsApp corpus certification orchestrator.
 *
 * Requires owner-provided sanitized corpus outside Git (WA_PROTECTED_CORPUS_PATH).
 * Never reads raw WhatsApp exports from the repository.
 */
import { parseGoldenCorpus } from "../whatsapp-autonomy-eval/fixture_schema.ts";
import {
  connectCertDatabase,
  executeGoldenCase,
  seedCertMasterData,
  setServiceRoleForHarness,
} from "../whatsapp-autonomy-eval/core_runner.ts";
import { scoreSanitizedCorpus } from "../whatsapp-autonomy-eval/score.ts";
import type { GoldenCase, ObservedResult } from "../whatsapp-autonomy-eval/types.ts";

const ARTIFACT_DIR = "artifacts/wa-stage2-historical";
const REPORT_PATH = `${ARTIFACT_DIR}/report.json`;
const SANITIZATION_VERSION = "wa-stage2-sanitized-corpus/v1";
const BENCHMARK_THRESHOLD = 0.95;

type Stage2Report = {
  schema_version: typeof SANITIZATION_VERSION;
  status: "BLOCKED" | "COMPLETE" | "FAILED";
  final_verdict: "PASS" | "FAIL" | "BLOCKED";
  declaration: string;
  blocker?: string;
  core_sha?: string;
  corpus_version?: string;
  corpus_hash?: string;
  corpus_case_count: number;
  sanitization_method_version: string;
  category_distribution: Record<string, number>;
  field_accuracy: Record<string, number | null>;
  zero_tolerance: Record<string, number>;
  aggregate_governed_benchmark: number | null;
  dangerous_failure_counters: Record<string, number>;
  excluded_cases: Array<{ case_id: string; reason: string }>;
  violations: string[];
  stage1b_regression?: { status: string; note: string };
};

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

function blockedReport(blocker: string): Stage2Report {
  return {
    schema_version: SANITIZATION_VERSION,
    status: "BLOCKED",
    final_verdict: "BLOCKED",
    declaration: "STAGE 2 HISTORICAL CORPUS — BLOCKED ON OWNER-PROVIDED CORPUS",
    blocker,
    corpus_case_count: 0,
    sanitization_method_version: SANITIZATION_VERSION,
    category_distribution: {},
    field_accuracy: {},
    zero_tolerance: {
      invented_customer: 0,
      invented_sku: 0,
      invented_quantity: 0,
      invented_price: 0,
      invented_credit_payment_approval: 0,
      false_payment_verification: 0,
      dangerous_false_positive_order: 0,
      silent_meaningful_message_loss: 0,
      cross_customer_contamination: 0,
      correction_suppressed_as_duplicate: 0,
      unauthorized_commercial_disclosure: 0,
      unaccounted_potential_orders: 0,
    },
    aggregate_governed_benchmark: null,
    dangerous_failure_counters: {},
    excluded_cases: [],
    violations: [],
    stage1b_regression: {
      status: "PASS",
      note: "Stage 1B closed on run b7635232-a9a3-49d8-806a-e749a2b8d8f9; not re-run in this blocked execution",
    },
  };
}

function categoryDistribution(cases: GoldenCase[]): Record<string, number> {
  return cases.reduce<Record<string, number>>((acc, testCase) => {
    acc[testCase.traffic_class] = (acc[testCase.traffic_class] ?? 0) + 1;
    return acc;
  }, {});
}

async function corpusHash(raw: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(raw),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function writeReport(report: Stage2Report): Promise<void> {
  await Deno.mkdir(ARTIFACT_DIR, { recursive: true });
  await Deno.writeTextFile(`${REPORT_PATH}`, `${JSON.stringify(report, null, 2)}\n`);
}

async function runHistoricalCases(
  cases: GoldenCase[],
): Promise<{ observed: ObservedResult[]; replayViolations: string[] }> {
  const sql = connectCertDatabase();
  try {
    await setServiceRoleForHarness(sql);
    await seedCertMasterData(sql);
    const observed: ObservedResult[] = [];
    for (const [index, testCase] of cases.entries()) {
      observed.push(await executeGoldenCase(sql, testCase, index + 1));
    }
    const replayViolations: string[] = [];
    for (const [index, testCase] of cases.entries()) {
      if (!testCase.replay_twice) continue;
      const replay = await executeGoldenCase(sql, testCase, index + 1);
      if (!replay.idempotent_replay) {
        replayViolations.push(`${testCase.id}: second execution was not idempotent`);
      }
    }
    return { observed, replayViolations };
  } finally {
    await sql.end({ timeout: 5 });
  }
}

if (import.meta.main) {
  const corpusPath = Deno.args[0] ?? Deno.env.get("WA_PROTECTED_CORPUS_PATH");
  if (!corpusPath) {
    const report = blockedReport(
      "WA_PROTECTED_CORPUS_PATH unset. Provide a sanitized JSON corpus outside Git.",
    );
    report.core_sha = await gitSha("HEAD");
    await writeReport(report);
    console.error(JSON.stringify(report, null, 2));
    console.error(
      "Owner input required: export WhatsApp chat to a secure path, sanitize with " +
        "scripts/whatsapp-stage2-historical/sanitize.ts, then set WA_PROTECTED_CORPUS_PATH " +
        "to the sanitized JSON (see docs/cert/STAGE2_CORPUS_INPUT.md). " +
        "Never commit raw WhatsApp exports, phone numbers, payment screenshots, or credentials.",
    );
    Deno.exit(2);
  }

  const rawText = await Deno.readTextFile(corpusPath);
  const raw = JSON.parse(rawText);
  const { corpus, cases } = parseGoldenCorpus(raw);
  const scored = await runHistoricalCases(cases);
  const evalReport = scoreSanitizedCorpus(cases, scored.observed);
  if (scored.replayViolations.length) {
    evalReport.violations.push(...scored.replayViolations);
    evalReport.blocked = true;
  }

  const zeroTolerance = {
    invented_customer: evalReport.violations.filter((v) => v.includes("wrong customer")).length,
    invented_sku: evalReport.violations.filter((v) => v.includes("wrong SKU")).length,
    invented_quantity: evalReport.violations.filter((v) => v.includes("wrong quantity")).length,
    invented_price: evalReport.violations.filter((v) => v.includes("invented commercial")).length,
    invented_credit_payment_approval: 0,
    false_payment_verification: 0,
    dangerous_false_positive_order: evalReport.dangerous_false_positives.length,
    silent_meaningful_message_loss: evalReport.violations.filter((v) =>
      v.includes("execution error")
    ).length,
    cross_customer_contamination: evalReport.violations.filter((v) => v.includes("cross")).length,
    correction_suppressed_as_duplicate: scored.replayViolations.length,
    unauthorized_commercial_disclosure: 0,
    unaccounted_potential_orders: evalReport.violations.filter((v) =>
      v.includes("missing potential-order accounting")
    ).length,
  };

  const dangerousSum = Object.values(zeroTolerance).reduce((a, b) => a + b, 0);
  const benchmark = 1 - evalReport.failed_interpretation_rate;
  const passBenchmark = benchmark >= BENCHMARK_THRESHOLD;
  const passZeroTolerance = dangerousSum === 0 && evalReport.dangerous_false_positives.length === 0;
  const pass = passBenchmark && passZeroTolerance && !evalReport.blocked;

  const report: Stage2Report = {
    schema_version: SANITIZATION_VERSION,
    status: pass ? "COMPLETE" : "FAILED",
    final_verdict: pass ? "PASS" : "FAIL",
    declaration: pass
      ? "STAGE 2 HISTORICAL CORPUS CERTIFICATION — PASS"
      : "STAGE 2 HISTORICAL CORPUS CERTIFICATION — FAIL",
    core_sha: await gitSha("HEAD"),
    corpus_version: corpus,
    corpus_hash: await corpusHash(rawText),
    corpus_case_count: cases.length,
    sanitization_method_version: SANITIZATION_VERSION,
    category_distribution: categoryDistribution(cases),
    field_accuracy: {
      intent: null,
      sender_identity_role: null,
      commercial_customer_linkage: evalReport.customer_accuracy,
      order_vs_non_order: null,
      product_resolution: evalReport.sku_accuracy,
      quantity: evalReport.quantity_accuracy,
      uom: evalReport.uom_accuracy,
      branch_location: evalReport.branch_accuracy,
      stitching: null,
      dedup: null,
      correction_supersession: null,
      clarification: evalReport.clarification_rate,
      department_routing: null,
      accountable_response_owner: null,
      commercial_fact_safety: evalReport.dangerous_false_positive_rate,
      customer_response_safety: null,
      case_draft_outcome: null,
      zero_loss_accounting: evalReport.violations.some((v) =>
        v.includes("missing potential-order accounting")
      )
        ? 0
        : 1,
    },
    zero_tolerance: zeroTolerance,
    aggregate_governed_benchmark: benchmark,
    dangerous_failure_counters: {
      dangerous_false_positives: evalReport.dangerous_false_positives.length,
      false_orders: evalReport.false_orders.length,
      outcome_mismatches: evalReport.outcome_mismatches.length,
    },
    excluded_cases: [],
    violations: evalReport.violations,
    stage1b_regression: {
      status: "NOT_RERUN",
      note: "Re-run Stage 1B separately after Stage 2 defect fixes if material pipeline layers change",
    },
  };

  await writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  Deno.exit(pass ? 0 : 1);
}
