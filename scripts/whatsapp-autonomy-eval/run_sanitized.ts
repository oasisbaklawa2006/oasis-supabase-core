import sanitizedFixture from "./fixtures/sanitized_golden_v1.json" with {
  type: "json",
};
import {
  connectCertDatabase,
  executeGoldenCase,
  seedCertMasterData,
  setServiceRoleForHarness,
} from "./core_runner.ts";
import { parseGoldenCorpus } from "./fixture_schema.ts";
import { scoreSanitizedCorpus } from "./score.ts";
import type { ObservedResult } from "./types.ts";

function printReport(report: ReturnType<typeof scoreSanitizedCorpus>): void {
  console.log(JSON.stringify(
    {
      total: report.total,
      traffic_class_distribution: report.traffic_class_distribution,
      auto_actioned: report.auto_actioned,
      straight_through_rate: report.straight_through_rate,
      clarification_rate: report.clarification_rate,
      policy_or_human_exception_rate: report.policy_or_human_exception_rate,
      failed_interpretation_rate: report.failed_interpretation_rate,
      dangerous_false_positives: report.dangerous_false_positives,
      dangerous_false_positive_rate: report.dangerous_false_positive_rate,
      false_orders: report.false_orders,
      outcome_mismatches: report.outcome_mismatches,
      customer_accuracy: report.customer_accuracy,
      branch_accuracy: report.branch_accuracy,
      sku_accuracy: report.sku_accuracy,
      quantity_accuracy: report.quantity_accuracy,
      uom_accuracy: report.uom_accuracy,
      blocked: report.blocked,
      violations: report.violations,
    },
    null,
    2,
  ));
}

async function runReplayChecks(
  cases: ReturnType<typeof parseGoldenCorpus>["cases"],
  sql: ReturnType<typeof connectCertDatabase>,
): Promise<string[]> {
  const violations: string[] = [];
  for (const [index, testCase] of cases.entries()) {
    if (!testCase.replay_twice) continue;
    const replay = await executeGoldenCase(sql, testCase, index + 1);
    if (!replay.idempotent_replay) {
      violations.push(`${testCase.id}: second execution was not idempotent`);
    }
    if (replay.observed_core_outcome !== testCase.expected_core_outcome) {
      violations.push(`${testCase.id}: replay core outcome mismatch`);
    }
  }
  return violations;
}

async function runHarness(
  cases: ReturnType<typeof parseGoldenCorpus>["cases"],
): Promise<{
  observed: ObservedResult[];
  replayViolations: string[];
}> {
  const sql = connectCertDatabase();
  try {
    await setServiceRoleForHarness(sql);
    await seedCertMasterData(sql);
    const observed: ObservedResult[] = [];
    for (const [index, testCase] of cases.entries()) {
      observed.push(await executeGoldenCase(sql, testCase, index + 1));
    }
    const replayViolations = await runReplayChecks(cases, sql);
    return { observed, replayViolations };
  } finally {
    await sql.end({ timeout: 5 });
  }
}

if (import.meta.main) {
  const { cases } = parseGoldenCorpus(sanitizedFixture);
  const { observed, replayViolations } = await runHarness(cases);
  const report = scoreSanitizedCorpus(cases, observed);
  if (replayViolations.length > 0) {
    report.violations.push(...replayViolations);
    report.blocked = true;
  }
  printReport(report);
  if (report.blocked) {
    console.error(
      "CERT-A sanitized corpus blocked:",
      report.violations.join("; "),
    );
    Deno.exit(1);
  }
  console.log("CERT-A sanitized corpus passed against live Core authority.");
}
