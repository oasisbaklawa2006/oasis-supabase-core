import { parseGoldenCorpus } from "./fixture_schema.ts";
import { runProtectedCases } from "./core_runner.ts";
import { scoreSanitizedCorpus } from "./score.ts";

async function readProtectedCorpus(path: string): Promise<unknown> {
  const text = await Deno.readTextFile(path);
  return JSON.parse(text);
}

if (import.meta.main) {
  const corpusPath = Deno.args[0] ??
    Deno.env.get("WA_PROTECTED_CORPUS_PATH");
  if (!corpusPath) {
    console.error(
      "Protected corpus path required. Pass as argv[1] or WA_PROTECTED_CORPUS_PATH.",
    );
    console.error(
      "Raw private WhatsApp exports must never be committed. Use a sanitized file outside git or a CI protected artifact.",
    );
    Deno.exit(2);
  }

  const raw = await readProtectedCorpus(corpusPath);
  const { corpus, cases } = parseGoldenCorpus(raw);
  const observed = await runProtectedCases(cases, corpus);
  const report = scoreSanitizedCorpus(cases, observed);

  const safeDiagnostics = observed.map((result) => ({
    case_id: result.case_id,
    observed_core_outcome: result.observed_core_outcome,
    observed_auto_actioned: result.observed_auto_actioned,
    error: result.error,
  }));

  console.log(JSON.stringify(
    {
      corpus,
      source: "protected",
      total: report.total,
      straight_through_rate: report.straight_through_rate,
      dangerous_false_positives: report.dangerous_false_positives,
      false_orders: report.false_orders,
      outcome_mismatches: report.outcome_mismatches,
      blocked: report.blocked,
      violations: report.violations,
      diagnostics: safeDiagnostics,
    },
    null,
    2,
  ));

  if (report.blocked) Deno.exit(1);
}
