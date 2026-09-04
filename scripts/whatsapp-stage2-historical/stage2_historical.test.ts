import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { inferExpectation } from "./expectations.ts";
import { buildEvidenceInterpretation } from "./interpretation_stub.ts";
import { parseWhatsAppExport } from "./parse_export.ts";
import { buildCertificationWindows } from "./segment.ts";
import type { ParsedHistoricalMessage, ZeroToleranceEntry } from "./types.ts";
import {
  ADMISSIBLE_ROUTING,
  listExpectedBusinessClasses,
  routingMatchesExpectation,
} from "./routing_contract.ts";
import {
  STAGE2_COUNTER_SEMANTICS,
  STAGE2_FIELD_ACCURACY_LABELS,
  STAGE2_PASS_VERDICT_CONTRACT,
} from "./pass_contract.ts";
import {
  buildReconciliationFromAccounting,
  buildZeroTolerance,
  scoreStage2Historical,
  zeroToleranceBlocksPass,
} from "./score_stage2.ts";
import {
  computeMessageAccounting,
  isAcknowledgementOnly,
  isActionableForCertification,
} from "./message_accounting.ts";
import {
  classifyError,
  reportJsonIsPrivacySafe,
  sanitizeDefectRootCause,
  sanitizeViolationLines,
} from "./privacy.ts";
import {
  buildBlockedReport,
  buildPreCoreEvalProvisionalReport,
  PROVISIONAL_PRE_CORE_BLOCKER,
  PROVISIONAL_PRE_CORE_DECLARATION,
} from "./report_builder.ts";
import { parseWhatsAppExport as parseSanitizerExport } from "./sanitize.ts";
import { resetPseudophoneRegistry } from "./to_golden.ts";
import type {
  GoldenCase,
  ObservedResult,
} from "../whatsapp-autonomy-eval/types.ts";
import { scoreSanitizedCorpus } from "../whatsapp-autonomy-eval/score.ts";
import { HARNESS_ENTITY_PREFIX } from "../whatsapp-autonomy-eval/core_runner.ts";
import {
  buildMediaPairedCanonical,
  MEDIA_ATTACHMENT_TOKEN,
  normalizeMediaSerialization,
  pairMediaReferencesToArchive,
  resolveReconciliationFailReason,
} from "./media_authority_reconciliation.ts";

const SAMPLE =
  `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250 to Main Store for Taj Sweets Bengaluru
[30/08/2026, 09:18:44] Priya Sales: Correction — make it 10 boxes not 12
[30/08/2026, 09:20:11] Accounts Team: UTR REF 123456789012 paid against invoice
[30/08/2026, 09:23:15] Messages and calls are end-to-end encrypted.`;

Deno.test("parseWhatsAppExport parses bracket timestamps and multiline bodies", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  assertEquals(messages.length, 4);
  assertEquals(messages[0].sender, "Priya Sales");
  assertEquals(messages[0].so_references.length, 0);
  assertEquals(messages[3].is_system, true);
});

Deno.test("inferExpectation labels order, amendment, and payment from evidence", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const order = messages[0];
  const amendment = messages[1];
  const payment = messages[2];
  assertEquals(inferExpectation(order, messages, [1]).expected_class, "ORDER");
  assertEquals(
    inferExpectation(amendment, messages, [1, 2]).expected_class,
    "ORDER_AMENDMENT",
  );
  assertEquals(
    inferExpectation(payment, messages, [3]).expected_class,
    "PAYMENT_PROOF",
  );
});

Deno.test("buildCertificationWindows accounts for each business message", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  assertEquals(windows.length, 3);
});

Deno.test("buildEvidenceInterpretation uses non-zero confidence for routing", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const focal = messages[0];
  const interpretation = buildEvidenceInterpretation(
    focal,
    "ORDER",
    "NEW_ORDER",
    "stage2-test",
    focal.body,
  ) as {
    confidence: number;
    conclusion: { intent: string; order_lines?: unknown[] };
  };
  assertEquals(interpretation.confidence > 0.5, true);
  assertEquals(interpretation.conclusion.intent, "ORDER");
  assertEquals(Array.isArray(interpretation.conclusion.order_lines), true);
});

Deno.test("inferExpectation labels payment query from evidence", () => {
  const paymentQuery: ParsedHistoricalMessage = {
    index: 1,
    timestamp_raw: "1/1/2026 10:00",
    timestamp_ms: null,
    sender: "Accounts",
    body: "Kindly update the rest party payment status for all orders",
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
  assertEquals(
    inferExpectation(paymentQuery, [paymentQuery], [1]).expected_class,
    "PAYMENT_QUERY",
  );
});

Deno.test("buildEvidenceInterpretation maps payment query to PAYMENT_ADVICE intent", () => {
  const paymentQuery: ParsedHistoricalMessage = {
    index: 1,
    timestamp_raw: "1/1/2026 10:00",
    timestamp_ms: null,
    sender: "Accounts",
    body: "Kindly update the rest party payment status",
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
  const interpretation = buildEvidenceInterpretation(
    paymentQuery,
    "PAYMENT_QUERY",
    "PAYMENT_QUERY",
    "stage2-payment-query",
    paymentQuery.body,
    "HUMAN_EXCEPTION_REQUIRED",
  ) as { confidence: number; conclusion: { intent: string } };
  assertEquals(interpretation.conclusion.intent, "PAYMENT_ADVICE");
  assertEquals(interpretation.confidence >= 0.9, true);
});

Deno.test("deleted messages preserve existence without inferring content", () => {
  const deleted: ParsedHistoricalMessage = {
    index: 1,
    timestamp_raw: "1/1/2026 10:00",
    timestamp_ms: null,
    sender: "User",
    body: "This message was deleted",
    is_forwarded: false,
    is_deleted: true,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
  assertEquals(
    inferExpectation(deleted, [deleted], [1]).expected_class,
    "DELETED_MESSAGE",
  );
});

Deno.test("parseWhatsAppExport retains business message with unusual sender line", () => {
  const text =
    `[30/08/2026, 09:15:22] Name (emoji-only display): Please dispatch balance goods today`;
  const messages = parseWhatsAppExport(text);
  assertEquals(messages.length, 1);
  assertEquals(messages[0].is_system, false);
  assertEquals(messages[0].body.includes("dispatch"), true);
});

Deno.test("acknowledgement-only messages remain accounted but skip certification windows", () => {
  const text =
    `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250
[30/08/2026, 09:16:00] Client: ok thanks`;
  const messages = parseWhatsAppExport(text);
  assertEquals(isAcknowledgementOnly(messages[1]), true);
  const windows = buildCertificationWindows(messages);
  assertEquals(windows.length, 1);
  const accounting = computeMessageAccounting(
    messages,
    new Set(windows.map((w) => w.focal_index)),
  );
  assertEquals(accounting.explicit_non_actionable_ack, 1);
  assertEquals(accounting.balanced, true);
});

Deno.test("routing contract rejects NULL and wrong outcomes", () => {
  assertEquals(
    routingMatchesExpectation("ORDER", "HUMAN_EXCEPTION_REQUIRED", false),
    true,
  );
  assertEquals(routingMatchesExpectation("ORDER", null, false), false);
  assertEquals(
    routingMatchesExpectation("ORDER", "AUTO_ELIGIBLE", true),
    false,
  );
  assertEquals(
    routingMatchesExpectation(
      "MEDIA_UNAVAILABLE",
      "FAILED_INTERPRETATION",
      false,
    ),
    true,
  );
  assertEquals(
    routingMatchesExpectation("ORDER", "FAILED_INTERPRETATION", false),
    false,
  );
});

Deno.test("interpretation stub sets media_status only for MEDIA_UNAVAILABLE class", () => {
  const focal = {
    index: 1,
    timestamp_raw: "1/1/2026 10:00",
    timestamp_ms: null,
    sender: "Client",
    body: "<image omitted>",
    media_type: "image",
    is_deleted: false,
    is_forwarded: false,
    is_system: false,
    party_hints: [],
    so_references: [],
    mentions_evergreen: false,
  };
  const delivery = buildEvidenceInterpretation(
    focal,
    "DELIVERY_ADDRESS",
    "DELIVERY_ADDRESS",
    "stage2-test-1",
    focal.body,
    "CLARIFICATION_REQUIRED",
  );
  assertEquals(
    (delivery.conclusion as Record<string, unknown>).media_status,
    undefined,
  );
  const media = buildEvidenceInterpretation(
    focal,
    "MEDIA_UNAVAILABLE",
    "MEDIA_UNAVAILABLE",
    "stage2-test-2",
    focal.body,
    "CLARIFICATION_REQUIRED",
  );
  assertEquals(
    (media.conclusion as Record<string, unknown>).media_status,
    "UNAVAILABLE",
  );
  const deliveryIntent = buildEvidenceInterpretation(
    { ...focal, body: "deliver to Indiranagar pincode 560038" },
    "DELIVERY_ADDRESS",
    "DELIVERY_ADDRESS",
    "stage2-test-3",
    "deliver to Indiranagar pincode 560038",
    "CLARIFICATION_REQUIRED",
  );
  assertEquals(
    (deliveryIntent.conclusion as Record<string, unknown>).intent,
    "DELIVERY_QUERY",
  );
});

Deno.test("every ExpectedBusinessClass has explicit routing contract", () => {
  for (const cls of listExpectedBusinessClasses()) {
    assertEquals(cls in ADMISSIBLE_ROUTING, true);
  }
});

Deno.test("unmapped expected class fails routing match", () => {
  assertEquals(
    routingMatchesExpectation(
      "NOT_A_CLASS" as never,
      "HUMAN_EXCEPTION_REQUIRED",
      false,
    ),
    false,
  );
});

Deno.test("reconciliation balanced when all business messages accounted", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const recon = buildReconciliationFromAccounting(messages, windows);
  assertEquals(recon.received_business_messages, 3);
  assertEquals(recon.unaccounted, 0);
  assertEquals(recon.balanced, true);
});

Deno.test("reconciliation fails when business message missing from windows", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages).slice(0, 1);
  const recon = buildReconciliationFromAccounting(messages, windows);
  assertEquals(recon.unaccounted > 0, true);
  assertEquals(recon.balanced, false);
});

Deno.test("system messages cannot offset missing business messages", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages).slice(0, 2);
  const recon = buildReconciliationFromAccounting(messages, windows);
  assertEquals(recon.excluded_system, 1);
  assertEquals(recon.unaccounted, 1);
  assertEquals(recon.balanced, false);
});

Deno.test("zeroToleranceBlocksPass rejects not_evaluated and positive counts", () => {
  assertEquals(
    zeroToleranceBlocksPass({
      x: { status: "not_evaluated", count: 0, reason: "test" },
    }),
    true,
  );
  assertEquals(
    zeroToleranceBlocksPass({ x: { status: "evaluated", count: 0 } }),
    false,
  );
});

Deno.test("zero tolerance entries are evidence-derived not hardcoded", () => {
  const zt = buildZeroTolerance(scoreSanitizedCorpus([], []), [], [], 0);
  for (const entry of Object.values(zt)) {
    assertEquals(entry.status, "evaluated");
  }
});

Deno.test("scoreStage2Historical flags missing observed results", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const golden: GoldenCase[] = windows.map((w) => ({
    id: w.window_id,
    traffic_class: w.traffic_class,
    input: {
      submitter_phone: "919999999999",
      submitter_name: w.sender,
      provider_message_id: w.window_id,
      message_body: "test",
      message_type: "text",
      interpretation: {
        confidence: 0.9,
        conclusion: { intent: "ORDER", summary: "x" },
      },
    },
    ground_truth: {
      intent: "NEW_ORDER",
      customer: null,
      branch: null,
      sku: null,
      quantity: null,
      uom: null,
      confirmed_so: false,
    },
    expected_core_outcome: w.expected_core_outcome,
    should_auto_action: false,
  }));
  const score = scoreStage2Historical(windows, golden, []);
  assertEquals(score.missing_observed_count, golden.length);
});

Deno.test("scoreStage2Historical records missing certification windows", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const orphanGolden: GoldenCase = {
    id: "win-orphan-order",
    traffic_class: "order",
    input: {
      submitter_phone: "919999999999",
      submitter_name: "PARTICIPANT_TEST",
      provider_message_id: "stage2-orphan",
      message_body: "orphan case",
      message_type: "text",
      interpretation: {
        confidence: 0.9,
        conclusion: { intent: "ORDER", summary: "x" },
      },
    },
    ground_truth: {
      intent: "NEW_ORDER",
      customer: null,
      branch: null,
      sku: null,
      quantity: null,
      uom: null,
      confirmed_so: false,
    },
    expected_core_outcome: "HUMAN_EXCEPTION_REQUIRED",
    should_auto_action: false,
  };
  const score = scoreStage2Historical(windows, [orphanGolden], []);
  assertEquals(
    score.execution_gaps.some((gap) =>
      gap.includes("missing certification window: win-orphan-order")
    ),
    true,
  );
});

Deno.test("buildBlockedReport keeps stage1b_regression non-passing", () => {
  const report = buildBlockedReport("test-blocker");
  assertEquals(report.stage1b_regression?.status, "NOT_RERUN");
  assertEquals(report.final_verdict, "BLOCKED");
});

Deno.test("privacy classification strips PII from error paths", () => {
  const fakeError = new Error(
    "duplicate key +919876543210 violates unique constraint",
  );
  assertEquals(classifyError(fakeError), "HARNESS_IDENTITY_COLLISION");
  const root = sanitizeDefectRootCause(null, false, fakeError.message);
  assertEquals(root.includes("919876543210"), false);
});

Deno.test("deterministic SHA-256 pseudophones are stable", async () => {
  resetPseudophoneRegistry();
  const { windowsToGoldenCases } = await import("./to_golden.ts");
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const casesA = await windowsToGoldenCases(windows, messages, "hash-a");
  resetPseudophoneRegistry();
  const casesB = await windowsToGoldenCases(windows, messages, "hash-a");
  assertEquals(
    casesA.map((c) => c.input.submitter_phone),
    casesB.map((c) => c.input.submitter_phone),
  );
});

Deno.test("resetCertWhatsAppHarness avoids TRUNCATE CASCADE", () => {
  const src = Deno.readTextFileSync(
    new URL("../whatsapp-autonomy-eval/core_runner.ts", import.meta.url),
  );
  assertEquals(/\btruncate\s+table\b/i.test(src), false);
  assertEquals(/\btruncate\b[\s\S]{0,40}\bcascade\b/i.test(src), false);
  assertEquals(src.includes(HARNESS_ENTITY_PREFIX), true);
});

Deno.test("deleted business messages are excluded from certification windows and reconciliation", () => {
  const order = parseWhatsAppExport(
    `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250`,
  )[0];
  const deleted: ParsedHistoricalMessage = {
    index: 2,
    timestamp_raw: "30/08/2026, 09:16:00",
    timestamp_ms: null,
    sender: "Client",
    body: "This message was deleted",
    is_forwarded: false,
    is_deleted: true,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
  const messages = [order, deleted];
  assertEquals(isActionableForCertification(deleted), false);
  const windows = buildCertificationWindows(messages);
  assertEquals(windows.length, 1);
  assertEquals(windows[0].focal_index, order.index);
  const accounting = computeMessageAccounting(
    messages,
    new Set(windows.map((w) => w.focal_index)),
  );
  assertEquals(accounting.deleted_business, 1);
  assertEquals(accounting.certification_windowed, 1);
  assertEquals(accounting.unaccounted_business, 0);
  assertEquals(accounting.balanced, true);
  const reconciliation = buildReconciliationFromAccounting(messages, windows);
  assertEquals(reconciliation.excluded_deleted_only, 1);
  assertEquals(reconciliation.active_accounted, 1);
  assertEquals(reconciliation.unaccounted, 0);
});

Deno.test("empty-body business messages are excluded from active reconciliation", () => {
  const order = parseWhatsAppExport(
    `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250`,
  )[0];
  const emptyBody: ParsedHistoricalMessage = {
    index: 2,
    timestamp_raw: "30/08/2026, 09:16:00",
    timestamp_ms: null,
    sender: "Client",
    body: "",
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
  const messages = [order, emptyBody];
  assertEquals(isActionableForCertification(emptyBody), false);
  const windows = buildCertificationWindows(messages);
  assertEquals(windows.length, 1);
  const accounting = computeMessageAccounting(
    messages,
    new Set(windows.map((w) => w.focal_index)),
  );
  assertEquals(accounting.empty_body_business, 1);
  assertEquals(accounting.unaccounted_business, 0);
  assertEquals(accounting.balanced, true);
  const reconciliation = buildReconciliationFromAccounting(messages, windows);
  assertEquals(reconciliation.excluded_empty_body_only, 1);
  assertEquals(reconciliation.unaccounted, 0);
});

Deno.test("computeMessageAccounting is the production implementation", async () => {
  const production = await import("./message_accounting.ts");
  assertEquals(computeMessageAccounting, production.computeMessageAccounting);
});

Deno.test("multi-file sanitize reindexes messages to avoid duplicate case IDs", async () => {
  const { parseWhatsAppExport } = await import("./parse_export.ts");
  const fileA =
    `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250`;
  const fileB = `[30/08/2026, 10:00:00] Amit Store: Need 6 boxes BAK-PIST-250`;
  const batchA = parseWhatsAppExport(fileA);
  const batchB = parseWhatsAppExport(fileB);
  const merged = [
    ...batchA.map((m) => ({ ...m, index: m.index })),
    ...batchB.map((m) => ({ ...m, index: batchA.length + m.index })),
  ];
  const ids = new Set(merged.map((m) => m.index));
  assertEquals(ids.size, merged.length);
  assertEquals(merged[1].index, 2);
});

Deno.test("golden cases pseudonymize submitter names", async () => {
  resetPseudophoneRegistry();
  const { windowsToGoldenCases } = await import("./to_golden.ts");
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const cases = await windowsToGoldenCases(windows, messages, "hash-a");
  for (const testCase of cases) {
    assertEquals(
      testCase.input.submitter_name.startsWith("PARTICIPANT_"),
      true,
    );
    assertEquals(testCase.input.submitter_name.includes("Priya"), false);
  }
});

Deno.test("historical artifact documents Stage-2 v3 PASS certification evidence", () => {
  const reportPath = new URL(
    "../../artifacts/wa-stage2-historical/report.json",
    import.meta.url,
  );
  const report = JSON.parse(Deno.readTextFileSync(reportPath));
  assertEquals(report.field_accuracy.clarification_rate != null, true);
  assertEquals("clarification" in report.field_accuracy, false);
  assertEquals(
    report.field_accuracy_labels?.clarification_rate,
    STAGE2_FIELD_ACCURACY_LABELS.clarification_rate,
  );
  assertEquals(
    report.counter_semantics?.outcome_mismatches,
    STAGE2_COUNTER_SEMANTICS.outcome_mismatches,
  );
  assertEquals(report.pass_verdict_contract, STAGE2_PASS_VERDICT_CONTRACT);
  assertEquals(report.final_verdict, "PASS");
  assertEquals(report.status, "COMPLETE");
  assertEquals(
    report.corpus_hash,
    "7ffd30f9e00dc57f7bf7efa1396de338ff8127ff6985a1a21e1f17a76a1790bc",
  );
  assertEquals(report.parsed_message_count, 8979);
  assertEquals(report.commercial_party_contexts, 578);
  assertEquals(report.certification_window_count, 8804);
  assertEquals(report.executed_window_count, 8804);
  assertEquals(report.partial_run, false);
  assertEquals(report.authoritative_release_evidence, true);
  for (const entry of Object.values(
    report.zero_tolerance as Record<string, ZeroToleranceEntry>,
  )) {
    assertEquals(entry.status, "evaluated");
    assertEquals(entry.count, 0);
  }
  assertEquals(
    (report.aggregate_governed_benchmark ?? 0) >= 0.95,
    true,
  );
  assertEquals(report.reconciliation.balanced, true);
  assertEquals(report.reconciliation.unaccounted, 0);
  assertEquals(report.defects_found.length, 0);
  assertEquals(report.violations.length, 0);
  assertEquals(report.dangerous_failure_counters.outcome_mismatches > 0, true);
});

Deno.test("partial-run missing observed prevents silent pass", () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const windows = buildCertificationWindows(messages);
  const observed: ObservedResult[] = [{
    case_id: windows[0].window_id,
    observed_core_outcome: "HUMAN_EXCEPTION_REQUIRED",
    observed_auto_actioned: false,
    observed_customer: null,
    observed_branch: null,
    observed_sku: null,
    observed_quantity: null,
    observed_uom: null,
    potential_order_state: null,
    potential_order_disposition: null,
    draft_id: null,
    promoted_order_id: null,
    selling_price: null,
    payment_terms: null,
    invented_commercial_leaked: false,
    idempotent_replay: false,
    error: null,
  }];
  const golden: GoldenCase[] = windows.map((w) => ({
    id: w.window_id,
    traffic_class: w.traffic_class,
    input: {
      submitter_phone: "919999999999",
      submitter_name: w.sender,
      provider_message_id: w.window_id,
      message_body: "test",
      message_type: "text",
      interpretation: {
        confidence: 0.9,
        conclusion: { intent: "ORDER", summary: "x" },
      },
    },
    ground_truth: {
      intent: "NEW_ORDER",
      customer: null,
      branch: null,
      sku: null,
      quantity: null,
      uom: null,
      confirmed_so: false,
    },
    expected_core_outcome: w.expected_core_outcome,
    should_auto_action: false,
  }));
  const score = scoreStage2Historical(windows, golden, observed);
  assertEquals(score.missing_observed_count, 2);
});

function paymentMessage(body: string): ParsedHistoricalMessage {
  return {
    index: 1,
    timestamp_raw: "1/1/2026 10:00",
    timestamp_ms: null,
    sender: "Accounts",
    body,
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    media_type: null,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
}

Deno.test("payment query classification precedes payment proof", () => {
  assertEquals(
    inferExpectation(paymentMessage("when paid?"), [
      paymentMessage("when paid?"),
    ], [1])
      .expected_class,
    "PAYMENT_QUERY",
  );
  assertEquals(
    inferExpectation(paymentMessage("payment status?"), [
      paymentMessage("payment status?"),
    ], [1])
      .expected_class,
    "PAYMENT_QUERY",
  );
  assertEquals(
    inferExpectation(paymentMessage("payment pending?"), [
      paymentMessage("payment pending?"),
    ], [1])
      .expected_class,
    "PAYMENT_QUERY",
  );
  assertEquals(
    inferExpectation(paymentMessage("payment done"), [
      paymentMessage("payment done"),
    ], [1])
      .expected_class,
    "PAYMENT_PROOF",
  );
  assertEquals(
    inferExpectation(
      paymentMessage("UTR REF 123456789012 NEFT received"),
      [paymentMessage("UTR REF 123456789012 NEFT received")],
      [1],
    ).expected_class,
    "PAYMENT_PROOF",
  );
});

Deno.test("buildPreCoreEvalProvisionalReport emits deterministic PROVISIONAL state", async () => {
  const messages = parseWhatsAppExport(SAMPLE);
  const ingest = {
    source_path: "sample.txt",
    corpus_bytes: 100,
    corpus_hash: "abc",
    messages,
    date_range: { start: "1/1/2026", end: "2/1/2026" },
    unique_senders: 2,
    commercial_party_contexts: 1,
  };
  const windows = buildCertificationWindows(messages);
  const report = await buildPreCoreEvalProvisionalReport(
    ingest,
    windows,
    "core-sha",
    "harness-sha",
  );
  assertEquals(report.status, "PROVISIONAL");
  assertEquals(report.final_verdict, "PROVISIONAL");
  assertEquals(report.declaration, PROVISIONAL_PRE_CORE_DECLARATION);
  assertEquals(report.blocker, PROVISIONAL_PRE_CORE_BLOCKER);
  assertEquals(report.executed_window_count, 0);
});

Deno.test("sanitizer keeps unknown timestamped line as separate business record", () => {
  const text = `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes today
[30/08/2026, 09:16:00] Unknown display name without colon body continues here`;
  const messages = parseSanitizerExport(text);
  assertEquals(messages.length, 2);
  assertEquals(messages[0].body_raw.includes("12 boxes"), true);
  assertEquals(messages[0].body_raw.includes("Unknown display"), false);
  assertEquals(messages[1].is_system, false);
  assertEquals(messages[1].sender_raw, "[unparsed-sender]");
  assertEquals(messages[1].body_raw.includes("Unknown display"), true);
});

Deno.test("blocked report and violations exclude raw PII from errors", () => {
  const rawError =
    "duplicate key +919876543210 violates constraint; body=UTR REF 123456789012 paid";
  const report = buildBlockedReport(classifyError(new Error(rawError)));
  report.violations = sanitizeViolationLines([
    `win-1: execution error: ${rawError}`,
  ]);
  const serialized = JSON.stringify(report);
  assertEquals(reportJsonIsPrivacySafe(serialized), true);
  assertEquals(serialized.includes("919876543210"), false);
  assertEquals(serialized.includes("123456789012"), false);
});

Deno.test("sanitizeViolationLine redacts sensitive case prefixes for known-safe suffixes", () => {
  const phone = "+919876543210: wrong customer auto-action";
  const email = "buyer@example.com: wrong SKU auto-action";
  const amount = "UTR REF 123456789012: wrong quantity auto-action";
  const sanitized = sanitizeViolationLines([phone, email, amount]);
  assertEquals(sanitized[0], "[PHONE]: wrong customer auto-action");
  assertEquals(sanitized[1], "[EMAIL]: wrong SKU auto-action");
  assertEquals(sanitized[2], "UTR REF [PHONE]: wrong quantity auto-action");
  const serialized = JSON.stringify({ violations: sanitized });
  assertEquals(reportJsonIsPrivacySafe(serialized), true);
  assertEquals(serialized.includes("919876543210"), false);
  assertEquals(serialized.includes("buyer@example.com"), false);
  assertEquals(serialized.includes("123456789012"), false);
});

Deno.test("sanitizeViolationLine classifies multiline execution errors safely", () => {
  const rawError = "line1\nline2 +919876543210 body=secret payment text";
  const sanitized = sanitizeViolationLines([
    `win-1: execution error: ${rawError}`,
    "win-2: wrong customer auto-action",
    "unclassified raw corpus snippet with secret order details",
  ]);
  assertEquals(sanitized[0], "win-1: CERT_EXECUTION_ERROR");
  assertEquals(sanitized[1], "win-2: wrong customer auto-action");
  assertEquals(sanitized[2], "CERTIFICATION_VIOLATION");
  assertEquals(
    reportJsonIsPrivacySafe(JSON.stringify({ violations: sanitized })),
    true,
  );
});

Deno.test("media serialization normalization maps omitted and attached markers", () => {
  const textBody = "Please send 12 boxes to Main Store\nimage omitted";
  const mediaBody =
    "Please send 12 boxes to Main Store\n<attached: 00000011-PHOTO-2025-09-11-19-25-03.jpg>";
  assertEquals(
    normalizeMediaSerialization(textBody),
    normalizeMediaSerialization(mediaBody),
  );
  assertEquals(
    normalizeMediaSerialization("video omitted"),
    MEDIA_ATTACHMENT_TOKEN,
  );
  assertEquals(
    normalizeMediaSerialization("<attached: invoice.pdf>"),
    MEDIA_ATTACHMENT_TOKEN,
  );
  assertEquals(
    normalizeMediaSerialization("for Taj Sweets order confirmed"),
    "for Taj Sweets order confirmed",
  );
});

function mediaMessage(
  index: number,
  body: string,
  mediaType: string | null = null,
): ParsedHistoricalMessage {
  return {
    index,
    timestamp_raw: `1/1/2026 10:0${index}`,
    timestamp_ms: null,
    sender: "Sender",
    body,
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    media_type: mediaType,
    so_references: [],
    party_hints: [],
    mentions_evergreen: false,
  };
}

Deno.test("buildMediaPairedCanonical handles shorter media export without crash", () => {
  const textMessages = parseWhatsAppExport(
    `[1/1/2026, 10:00] A: hello
[1/1/2026, 10:01] B: world`,
  );
  const mediaMessages = parseWhatsAppExport(`[1/1/2026, 10:00] A: hello`);
  const textNorm = textMessages.map((message) => ({
    ordinal: message.index,
    timestamp_raw: message.timestamp_raw,
    timestamp_ms: message.timestamp_ms,
    sender_pseudonym: message.sender,
    message_type: "text",
    body_normalized: normalizeMediaSerialization(message.body),
    media_marker_present: false,
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    party_hints: [],
    so_references: [],
    mentions_evergreen: false,
  }));
  const paired = buildMediaPairedCanonical(
    textMessages,
    mediaMessages,
    textNorm,
  );
  assertEquals(paired.length, 2);
  assertEquals(paired[1].body, "world");
});

Deno.test("buildMediaPairedCanonical handles longer media export without crash", () => {
  const textMessages = parseWhatsAppExport(`[1/1/2026, 10:00] A: hello`);
  const mediaMessages = parseWhatsAppExport(
    `[1/1/2026, 10:00] A: hello
[1/1/2026, 10:01] B: extra`,
  );
  const textNorm = textMessages.map((message) => ({
    ordinal: message.index,
    timestamp_raw: message.timestamp_raw,
    timestamp_ms: message.timestamp_ms,
    sender_pseudonym: message.sender,
    message_type: "text",
    body_normalized: normalizeMediaSerialization(message.body),
    media_marker_present: false,
    is_forwarded: false,
    is_deleted: false,
    is_system: false,
    party_hints: [],
    so_references: [],
    mentions_evergreen: false,
  }));
  const paired = buildMediaPairedCanonical(
    textMessages,
    mediaMessages,
    textNorm,
  );
  assertEquals(paired.length, 1);
  assertEquals(paired[0].body, "hello");
});

Deno.test("unequal export lengths classify as message mismatch fail reason", () => {
  const failReason = resolveReconciliationFailReason(
    {
      MEDIA_MARKER_ONLY: 0,
      EXPORT_FORMAT_ONLY: 0,
      ACTUAL_TEXT_DIFFERENCE: 0,
      SENDER_DIFFERENCE: 0,
      TIMESTAMP_DIFFERENCE: 0,
      MESSAGE_BOUNDARY_DIFFERENCE: 0,
      MISSING_MESSAGE: 0,
      EXTRA_MESSAGE: 1,
      OTHER: 0,
    },
    1,
    2,
    1,
    578,
    578,
    8804,
    true,
  );
  assertEquals(failReason, "MEDIA_PAIRING_MESSAGE_MISMATCH");
});

Deno.test("normalized hash mismatch uses distinct fail reason", () => {
  const failReason = resolveReconciliationFailReason(
    {
      MEDIA_MARKER_ONLY: 0,
      EXPORT_FORMAT_ONLY: 0,
      ACTUAL_TEXT_DIFFERENCE: 0,
      SENDER_DIFFERENCE: 0,
      TIMESTAMP_DIFFERENCE: 0,
      MESSAGE_BOUNDARY_DIFFERENCE: 0,
      MISSING_MESSAGE: 0,
      EXTRA_MESSAGE: 0,
      OTHER: 0,
    },
    0,
    8979,
    8979,
    578,
    578,
    8804,
    false,
  );
  assertEquals(failReason, "MEDIA_PAIRING_NORMALIZED_HASH_MISMATCH");
});

Deno.test("extension-only archive pairing consumes each zip entry once", () => {
  const messages = [
    mediaMessage(1, "first image share", "image"),
    mediaMessage(2, "second image share", "image"),
  ];
  const pairing = pairMediaReferencesToArchive(messages, [
    { name: "only-one.jpg", size: 100 },
  ]);
  assertEquals(pairing.successfully_paired, 1);
  assertEquals(pairing.unpaired, 1);
});

Deno.test("attached filename pairing consumes duplicate references once", () => {
  const messages = [
    mediaMessage(1, "<attached: shared.jpg>", "image"),
    mediaMessage(2, "<attached: shared.jpg>", "image"),
  ];
  const pairing = pairMediaReferencesToArchive(messages, [
    { name: "shared.jpg", size: 100 },
  ]);
  assertEquals(pairing.successfully_paired, 1);
  assertEquals(pairing.unpaired, 1);
});
