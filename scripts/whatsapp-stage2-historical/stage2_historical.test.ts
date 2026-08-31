import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { inferExpectation } from "./expectations.ts";
import { buildEvidenceInterpretation } from "./interpretation_stub.ts";
import { parseWhatsAppExport } from "./parse_export.ts";
import { buildCertificationWindows } from "./segment.ts";
import type { ParsedHistoricalMessage } from "./types.ts";
import {
  ADMISSIBLE_ROUTING,
  listExpectedBusinessClasses,
  routingMatchesExpectation,
} from "./routing_contract.ts";
import {
  buildReconciliationFromAccounting,
  buildZeroTolerance,
  scoreStage2Historical,
  zeroToleranceBlocksPass,
} from "./score_stage2.ts";
import {
  computeMessageAccounting,
  isAcknowledgementOnly,
} from "./message_accounting.ts";
import { classifyError, sanitizeDefectRootCause } from "./privacy.ts";
import { resetPseudophoneRegistry } from "./to_golden.ts";
import type {
  GoldenCase,
  ObservedResult,
} from "../whatsapp-autonomy-eval/types.ts";
import { scoreSanitizedCorpus } from "../whatsapp-autonomy-eval/score.ts";
import { HARNESS_ENTITY_PREFIX } from "../whatsapp-autonomy-eval/core_runner.ts";

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
  assertEquals(src.includes("truncate table"), false);
  assertEquals(src.includes(HARNESS_ENTITY_PREFIX), true);
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
