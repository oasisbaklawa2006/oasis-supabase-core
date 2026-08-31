import { assertEquals } from "jsr:@std/assert";
import { inferExpectation } from "./expectations.ts";
import { buildEvidenceInterpretation } from "./interpretation_stub.ts";
import { parseWhatsAppExport } from "./parse_export.ts";
import { buildCertificationWindows } from "./segment.ts";
import type { ParsedHistoricalMessage } from "./types.ts";

const SAMPLE = `[30/08/2026, 09:15:22] Priya Sales: Please send 12 boxes BAK-PIST-250 to Main Store for Taj Sweets Bengaluru
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
  ) as { confidence: number; conclusion: { intent: string; order_lines?: unknown[] } };
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
  assertEquals(inferExpectation(paymentQuery, [paymentQuery], [1]).expected_class, "PAYMENT_QUERY");
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
  assertEquals(inferExpectation(deleted, [deleted], [1]).expected_class, "DELETED_MESSAGE");
});
