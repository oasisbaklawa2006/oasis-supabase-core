import { buildBlockedHistoricalMediaReport } from "./blocked_report.ts";

Deno.test("blocked report documents passVerdict contract and prior evidence path", async () => {
  const report = await buildBlockedHistoricalMediaReport();
  if (!report.pass_verdict_contract?.includes("correction_continuation")) {
    throw new Error("missing pass verdict contract");
  }
  if (!report.prior_certified_run_evidence?.includes("prior-certified-run-evidence.json")) {
    throw new Error("missing prior evidence pointer");
  }
  if (report.case_results != null) {
    throw new Error("blocked report must not include case_results");
  }
});
